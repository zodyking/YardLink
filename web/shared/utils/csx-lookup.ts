/**
 * ShipCSX's public shipment lookup. People check containers there themselves:
 * Yard Link opens the page and supplies the numbers, it never drives the site.
 */
export const SHIPCSX_LOOKUP_URL = 'https://next.shipcsx.com/#/shipment/lookup'
/** What goes in the lookup's reference box when there is no pickup number. */
export const SHIPCSX_REFERENCE = '0000'

/** CSX facilities a location can be mapped to, as named in ShipCSX's list. */
export const SHIPCSX_TERMINALS = [
  'North Bergen',
  'Little Ferry',
  'South Kearny',
  'Elizabeth',
  'Newark',
] as const
export type ShipcsxTerminalName = (typeof SHIPCSX_TERMINALS)[number]
/** Equipment rows on ShipCSX's lookup form, so containers go in threes. */
export const SHIPCSX_BATCH_SIZE = 3

export function chunkShipcsxEquipment<T>(items: readonly T[], size = SHIPCSX_BATCH_SIZE): T[][] {
  const chunks: T[][] = []
  for (let i = 0; i < items.length; i += size) chunks.push(items.slice(i, i + size))
  return chunks
}

export const CSX_LOOKUP_TABS = ['NOTIFIED', 'ENROUTE', 'IN_GATE', 'OTHERS', 'NOT_FOUND'] as const
export type CsxLookupTab = (typeof CSX_LOOKUP_TABS)[number]

export interface CsxLookupCard {
  equipmentNumber: string
  loadEmpty: string | null
  waybillDate: string | null
  inGateReadiness: string | null
  gateWindow: string | null
  resultTab: CsxLookupTab
}

export interface CsxLookupParseResult {
  cards: CsxLookupCard[]
  tabCounts: Partial<Record<Exclude<CsxLookupTab, 'NOT_FOUND'>, number>>
}

const TAB_ALIASES: Record<string, Exclude<CsxLookupTab, 'NOT_FOUND'>> = {
  'NOTIFIED': 'NOTIFIED',
  'ENROUTE': 'ENROUTE',
  'EN-ROUTE': 'ENROUTE',
  'IN-GATE': 'IN_GATE',
  'INGATE': 'IN_GATE',
  'IN GATE': 'IN_GATE',
  'OTHERS': 'OTHERS',
}

function compactEquip(value: string): string {
  return value.toUpperCase().replace(/[^A-Z0-9]/g, '')
}

function labelValue(block: string, labels: string[]): string | null {
  for (const label of labels) {
    const match = block.match(new RegExp(`${label}\\s*[:\\-]?\\s*([^\\n]+)`, 'i'))
    const value = match?.[1]?.trim()
    if (value) return value.replace(/\s+/g, ' ')
  }
  return null
}

function tabFromHeading(heading: string): Exclude<CsxLookupTab, 'NOT_FOUND'> | null {
  const key = heading.toUpperCase().replace(/\s+/g, ' ').trim()
  return TAB_ALIASES[key] ?? TAB_ALIASES[key.replace(/[^A-Z]/g, '')] ?? null
}

/**
 * Parse ShipCSX "Shipment Lookup Results" page text. Never used to book
 * a reservation — availability / Submit copy is ignored.
 */
export function parseShipcsxLookupText(text: string): CsxLookupParseResult {
  const source = text ?? ''
  const tabCounts: CsxLookupParseResult['tabCounts'] = {}

  for (const match of source.matchAll(/(NOTIFIED|ENROUTE|EN-ROUTE|IN-GATE|IN GATE|OTHERS)\s*\((\d+)\)/gi)) {
    const tab = tabFromHeading(match[1] ?? '')
    if (tab) tabCounts[tab] = Number(match[2])
  }

  const cards: CsxLookupCard[] = []
  const cardBlocks = source.split(/(?=[A-Z]{4}\s?\d{6,7})/g)

  for (const block of cardBlocks) {
    const equipMatch = block.match(/\b([A-Z]{4})\s?(\d{6,7})\b/)
    if (!equipMatch) continue
    const equipmentNumber = compactEquip(`${equipMatch[1]}${equipMatch[2]}`)
    if (equipmentNumber.length < 10) continue
    if (/RESERVATION|SUBMIT|AVAILABLE/.test(block.toUpperCase()) && !/WAYBILL|IN-GATE|LOAD/.test(block.toUpperCase())) {
      continue
    }

    let resultTab: CsxLookupTab = 'NOT_FOUND'
    const active = Object.entries(tabCounts).find(([, count]) => (count ?? 0) > 0)?.[0] as CsxLookupTab | undefined
    if (active) resultTab = active
    if (/READY TO IN-GATE|READY TO INGATE/i.test(block)) resultTab = 'IN_GATE'
    else if (/ENROUTE|EN-ROUTE/i.test(block) && !/IN-GATE/i.test(block)) resultTab = 'ENROUTE'
    else if (/NOTIFIED/i.test(block) && !/IN-GATE/i.test(block)) resultTab = 'NOTIFIED'

    cards.push({
      equipmentNumber,
      loadEmpty: labelValue(block, ['Load / Empty', 'Load/Empty']),
      waybillDate: labelValue(block, ['Waybill Date']),
      inGateReadiness: labelValue(block, ['In-Gate Readiness', 'In Gate Readiness']),
      gateWindow: labelValue(block, ['Gate Window']),
      resultTab,
    })
  }

  return { cards, tabCounts }
}

/** The card for a container. ShipCSX shows the initial and serial, sometimes without the check digit. */
export function matchLookupCard(cards: CsxLookupCard[], equipmentNumber: string): CsxLookupCard | null {
  const needle = compactEquip(equipmentNumber).slice(0, 10)
  return cards.find(card => compactEquip(card.equipmentNumber).slice(0, 10) === needle) ?? null
}


/** ShipCSX's lookup asks for a 4-letter initial and 6-digit serial (no check digit). */
export interface ShipcsxEquipmentParts {
  initial: string
  number: string
}

export function shipcsxEquipmentParts(equipmentNumber: string): ShipcsxEquipmentParts | null {
  const compact = compactEquip(equipmentNumber)
  const match = compact.match(/^([A-Z]{4})(\d{6})/)
  if (!match?.[1] || !match[2]) return null
  return { initial: match[1], number: match[2] }
}

/** The CSX facility a stored or typed name means, if it plainly means one. */
export function shipcsxTerminalName(wanted?: string | null): ShipcsxTerminalName | null {
  const needle = (wanted ?? '').replace(/\s+/g, ' ').trim().toLowerCase()
  if (!needle) return null
  const exact = SHIPCSX_TERMINALS.find(name => name.toLowerCase() === needle)
  if (exact) return exact
  const close = SHIPCSX_TERMINALS.filter((name) => {
    const label = name.toLowerCase()
    return label.includes(needle) || needle.includes(label)
  })
  return close.length === 1 ? (close[0] ?? null) : null
}
