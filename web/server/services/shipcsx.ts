import { and, asc, desc, eq, inArray, isNull, ne, or } from 'drizzle-orm'
import { alias } from 'drizzle-orm/pg-core'
import { containerDutyCycles, containers, csxShipmentSnapshots, locations } from '../database/schema'
import type { DbExecutor } from '../utils/db'
import type { AuthContext } from '../utils/session'
import { loadCompanySettings } from '../utils/settings'
import {
  SHIPCSX_BATCH_SIZE,
  SHIPCSX_TERMINALS,
  chunkShipcsxEquipment,
  matchLookupCard,
  parseShipcsxLookupText,
  shipcsxTabFromHeading,
  shipcsxTerminalName,
  type CsxLookupCard,
} from '#shared/utils/csx-lookup'
import { normalizeContainerNumber } from '#shared/utils/iso6346'
import { shipcsxStatusLabel } from '#shared/utils/shipcsx-status'

/** The CSX location Check CSX uses when Settings names none. */
const FALLBACK_TERMINAL = 'North Bergen'

export interface ShipcsxBox {
  containerId: string
  number: string
}

export interface ShipcsxCheck {
  terminal: string
  boxes: ShipcsxBox[]
}

/**
 * The CSX location a container belongs to: the one its current duty cycle
 * started at, i.e. where it was taken out. A rail yard pinned to a CSX
 * location counts, as does a rail yard named after one.
 */
function terminalFor(start: { shipcsxTerminal: string | null, name: string | null, type: string | null } | null) {
  if (!start) return null
  return shipcsxTerminalName(start.shipcsxTerminal)
    ?? (start.type === 'RAIL_TERMINAL' ? shipcsxTerminalName(start.name) : null)
}

/**
 * A system-wide Check CSX: every container that is loaded, at a customer or
 * at a company yard, queued by the CSX location each came out of
 * (Settings' location when there's no history), one search per batch. A
 * container the person opened Check CSX from leads its location's queue.
 */
export async function shipcsxCheckPlan(db: DbExecutor, auth: AuthContext, firstContainerId?: string | null) {
  const settings = await loadCompanySettings(db)
  const fallback = shipcsxTerminalName(settings.shipcsxDefaultTerminal) ?? FALLBACK_TERMINAL
  const here = alias(locations, 'here')
  const start = alias(locations, 'start')

  const rows = await db
    .select({
      containerId: containers.id,
      number: containers.number,
      startTerminal: start.shipcsxTerminal,
      startName: start.name,
      startType: start.type,
    })
    .from(containers)
    .leftJoin(here, eq(here.id, containers.currentLocationId))
    .leftJoin(containerDutyCycles, and(
      eq(containerDutyCycles.containerId, containers.id),
      eq(containerDutyCycles.status, 'ACTIVE'),
    ))
    .leftJoin(start, eq(start.id, containerDutyCycles.startLocationId))
    .where(and(
      eq(containers.companyId, auth.companyId),
      isNull(containers.deletedAt),
      or(
        firstContainerId ? eq(containers.id, firstContainerId) : undefined,
        and(
          ne(containers.activePoolState, 'INACTIVE'),
          or(eq(containers.isLoaded, true), inArray(here.type, ['CUSTOMER', 'COMPANY_YARD'])),
        ),
      ),
    ))
    .orderBy(asc(containers.number))

  const byTerminal = new Map<string, ShipcsxBox[]>()
  for (const row of rows) {
    const terminal = terminalFor({ shipcsxTerminal: row.startTerminal, name: row.startName, type: row.startType }) ?? fallback
    const list = byTerminal.get(terminal) ?? []
    const box = { containerId: row.containerId, number: row.number }
    if (row.containerId === firstContainerId) list.unshift(box)
    else list.push(box)
    byTerminal.set(terminal, list)
  }

  // The opened container's location first, then the list's own order.
  const firstTerminal = [...byTerminal].find(([, list]) => list[0]?.containerId === firstContainerId)?.[0]
  const order = [...SHIPCSX_TERMINALS].sort((a, b) => Number(b === firstTerminal) - Number(a === firstTerminal))
  const checks: ShipcsxCheck[] = []
  for (const terminal of order) {
    for (const boxes of chunkShipcsxEquipment(byTerminal.get(terminal) ?? [], SHIPCSX_BATCH_SIZE)) {
      checks.push({ terminal, boxes })
    }
  }
  return { total: rows.length, checks }
}

/** ShipCSX's results page, as opposed to the form, a challenge or an error. */
function looksLikeResults(text: string): boolean {
  return /shipment lookup results|(NOTIFIED|ENROUTE|IN-GATE|OTHERS)\s*\(\d+\)/i.test(text)
}

/**
 * Save what ShipCSX's results said about the containers just searched. The
 * text comes from the person's own lookup in the app, one entry per results
 * tab (ShipCSX shows one tab's cards at a time). Every card's fields are
 * kept, filed under the container's current duty cycle; a container no tab
 * listed is saved as not on CSX, unless the person typed the search
 * themselves, when only the listed containers are saved.
 */
export async function saveShipcsxResults(
  db: DbExecutor,
  auth: AuthContext,
  input: {
    terminal: string
    containerIds: string[]
    tabs: Array<{ tab?: string | null, text: string }>
    /** The person typed the search: only containers the results list are saved. */
    listedOnly?: boolean
  },
) {
  if (!input.tabs.some(page => looksLikeResults(page.text))) {
    throw createError({ statusCode: 422, statusMessage: 'That page isn\'t ShipCSX search results yet.' })
  }
  const terminal = shipcsxTerminalName(input.terminal) ?? input.terminal.trim().slice(0, 80)

  const cards: CsxLookupCard[] = []
  let asOf: string | null = null
  let tabCounts = {}
  for (const page of input.tabs) {
    const parsed = parseShipcsxLookupText(page.text, page.tab ? shipcsxTabFromHeading(page.tab) : null)
    asOf ??= parsed.asOf
    tabCounts = { ...tabCounts, ...parsed.tabCounts }
    for (const card of parsed.cards) {
      if (!cards.some(seen => seen.equipmentNumber === card.equipmentNumber)) cards.push(card)
    }
  }

  const boxes = input.containerIds.length
    ? await db
      .select({ containerId: containers.id, number: containers.number, dutyCycleId: containerDutyCycles.id })
      .from(containers)
      .leftJoin(containerDutyCycles, and(
        eq(containerDutyCycles.containerId, containers.id),
        eq(containerDutyCycles.status, 'ACTIVE'),
      ))
      .where(and(eq(containers.companyId, auth.companyId), inArray(containers.id, input.containerIds)))
    : []
  const checkedAt = new Date()

  const results = []
  for (const box of boxes) {
    const card = matchLookupCard(cards, box.number)
    if (!card && input.listedOnly) continue
    const [row] = await db
      .insert(csxShipmentSnapshots)
      .values({
        companyId: auth.companyId,
        containerId: box.containerId,
        dutyCycleId: box.dutyCycleId,
        containerNumberNormalized: normalizeContainerNumber(box.number),
        terminalName: terminal,
        equipmentNumber: card?.equipmentNumber ?? normalizeContainerNumber(box.number),
        referenceUsed: '',
        resultTab: card?.resultTab ?? 'NOT_FOUND',
        loadEmpty: card?.loadEmpty ?? null,
        waybillDate: card?.waybillDate ?? null,
        inGateReadiness: card?.inGateReadiness ?? null,
        gateWindow: card?.gateWindow ?? null,
        rawPayload: { asOf, tabCounts, fields: card?.fields ?? {} },
        checkedAt,
      })
      .returning()
    results.push({ containerId: box.containerId, number: box.number, status: shipcsxStatusLabel(row) })
  }
  return { results }
}

/** The latest ShipCSX result for each container. */
export async function latestSnapshotsForContainers(
  db: DbExecutor,
  companyId: string,
  containerIds: string[],
) {
  if (!containerIds.length) return []
  const rows = await db
    .select()
    .from(csxShipmentSnapshots)
    .where(and(
      eq(csxShipmentSnapshots.companyId, companyId),
      inArray(csxShipmentSnapshots.containerId, containerIds),
    ))
    .orderBy(desc(csxShipmentSnapshots.checkedAt))

  const seen = new Set<string>()
  return rows.filter((row) => {
    const key = row.containerId ?? row.containerNumberNormalized
    if (seen.has(key)) return false
    seen.add(key)
    return true
  })
}
