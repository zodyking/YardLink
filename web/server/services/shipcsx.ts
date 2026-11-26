import { and, asc, desc, eq, inArray, isNull, ne, or } from 'drizzle-orm'
import { containers, csxShipmentSnapshots, locations } from '../database/schema'
import type { DbExecutor } from '../utils/db'
import type { AuthContext } from '../utils/session'
import { loadCompanySettings } from '../utils/settings'
import {
  SHIPCSX_REFERENCE,
  matchLookupCard,
  parseShipcsxLookupText,
  shipcsxTerminalName,
} from '#shared/utils/csx-lookup'
import { normalizeContainerNumber } from '#shared/utils/iso6346'
import { shipcsxStatusLabel } from '#shared/utils/shipcsx-status'

/** The CSX location Check CSX picks when Settings names none. */
const FALLBACK_TERMINAL = 'North Bergen'

export interface ShipcsxBox {
  containerId: string
  number: string
}

/**
 * What a Check CSX run covers: every loaded container in the pool and every
 * container sitting at a customer, so one run updates them all. A container
 * the person opened Check CSX from comes first even if it's neither.
 */
export async function shipcsxCheckPlan(db: DbExecutor, auth: AuthContext, firstContainerId?: string | null) {
  const settings = await loadCompanySettings(db)
  const terminal = shipcsxTerminalName(settings.shipcsxDefaultTerminal) ?? FALLBACK_TERMINAL

  const rows = await db
    .select({ containerId: containers.id, number: containers.number })
    .from(containers)
    .leftJoin(locations, eq(locations.id, containers.currentLocationId))
    .where(and(
      eq(containers.companyId, auth.companyId),
      isNull(containers.deletedAt),
      or(
        and(eq(containers.isLoaded, true), ne(containers.activePoolState, 'INACTIVE')),
        and(eq(containers.activePoolState, 'AT_LOCATION'), eq(locations.type, 'CUSTOMER')),
      ),
    ))
    .orderBy(asc(containers.number))

  let boxes: ShipcsxBox[] = rows
  if (firstContainerId) {
    const [first] = await db
      .select({ containerId: containers.id, number: containers.number })
      .from(containers)
      .where(and(
        eq(containers.companyId, auth.companyId),
        eq(containers.id, firstContainerId),
        isNull(containers.deletedAt),
      ))
      .limit(1)
    if (first) boxes = [first, ...rows.filter(row => row.containerId !== first.containerId)]
  }
  return { terminal, reference: SHIPCSX_REFERENCE, boxes }
}

/** ShipCSX's results page, as opposed to the form, a challenge or an error. */
function looksLikeResults(text: string): boolean {
  return /shipment lookup results|(NOTIFIED|ENROUTE|IN-GATE|OTHERS)\s*\(\d+\)/i.test(text)
}

/**
 * Save what a ShipCSX results page said about the containers just searched.
 * The page text comes from the person's own lookup in the app; a container
 * the page doesn't list is saved as not on CSX.
 */
export async function saveShipcsxResults(
  db: DbExecutor,
  auth: AuthContext,
  input: { terminal: string, containerIds: string[], pageText: string },
) {
  if (!looksLikeResults(input.pageText)) {
    throw createError({ statusCode: 422, statusMessage: 'That page isn\'t ShipCSX search results yet.' })
  }
  const terminal = shipcsxTerminalName(input.terminal) ?? input.terminal.trim().slice(0, 80)
  const boxes = input.containerIds.length
    ? await db
      .select({ containerId: containers.id, number: containers.number })
      .from(containers)
      .where(and(eq(containers.companyId, auth.companyId), inArray(containers.id, input.containerIds)))
    : []
  const { cards } = parseShipcsxLookupText(input.pageText)
  const checkedAt = new Date()

  const results = []
  for (const box of boxes) {
    const card = matchLookupCard(cards, box.number)
    const [row] = await db
      .insert(csxShipmentSnapshots)
      .values({
        companyId: auth.companyId,
        containerId: box.containerId,
        containerNumberNormalized: normalizeContainerNumber(box.number),
        terminalName: terminal,
        equipmentNumber: card?.equipmentNumber ?? normalizeContainerNumber(box.number),
        referenceUsed: SHIPCSX_REFERENCE,
        resultTab: card?.resultTab ?? 'NOT_FOUND',
        loadEmpty: card?.loadEmpty ?? null,
        waybillDate: card?.waybillDate ?? null,
        inGateReadiness: card?.inGateReadiness ?? null,
        gateWindow: card?.gateWindow ?? null,
        rawPayload: card ? { ...card } : {},
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
