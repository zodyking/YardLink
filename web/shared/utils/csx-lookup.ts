/**
 * ShipCSX's public shipment lookup. People check containers there themselves:
 * Yard Link opens the page and supplies the numbers, it never drives the site.
 */
export const SHIPCSX_LOOKUP_URL = 'https://next.shipcsx.com/#/shipment/lookup'

/** CSX facilities a location can be mapped to, as named in ShipCSX's list. */
export const SHIPCSX_TERMINALS = [
  'North Bergen',
  'Little Ferry',
  'South Kearny',
  'Elizabeth',
  'Newark',
] as const
export type ShipcsxTerminalName = (typeof SHIPCSX_TERMINALS)[number]
/**
 * Containers per search: a location's whole list goes in one search.
 * ShipCSX adds an equipment row each time one is filled; the phone puts back
 * any the form wouldn't take for a search of their own.
 */
export const SHIPCSX_BATCH_SIZE = 50

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
  /** Every label and value the card showed, as ShipCSX worded them. */
  fields: Record<string, string>
}

export interface CsxLookupParseResult {
  cards: CsxLookupCard[]
  tabCounts: Partial<Record<Exclude<CsxLookupTab, 'NOT_FOUND'>, number>>
  /** "As of 20:23 on 11/25/26": when ShipCSX's own data is from. */
  asOf: string | null
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

/** The labels a results card shows, value on the same line or the next. */
const CARD_LABELS = ['Load / Empty', 'Waybill Date', 'In-Gate Readiness', 'Gate Window', 'Out-Gate Readiness', 'Storage', 'Last Free Day', 'Status']

function labelValue(block: string, label: string): string | null {
  const pattern = label.replace(/[.*+?^${}()|[\]\\]/g, '\\$&').replace(/\s*\/\s*/g, '\\s*/\\s*').replace(/-/g, '[-\\s]?')
  const match = block.match(new RegExp(`${pattern}[ \\t]*[:\\-]?[ \\t]*(?:\\n[ \\t]*)*([^\\n]+)`, 'i'))
  const value = match?.[1]?.replace(/\s+/g, ' ').trim()
  return value || null
}

/** A results tab name as ShipCSX shows it ("IN-GATE") to our tab. */
export function shipcsxTabFromHeading(heading: string): Exclude<CsxLookupTab, 'NOT_FOUND'> | null {
  const key = heading.toUpperCase().replace(/\s+/g, ' ').trim()
  return TAB_ALIASES[key] ?? TAB_ALIASES[key.replace(/[^A-Z]/g, '')] ?? null
}

/**
 * Read ShipCSX's "Shipment Lookup Results" page text. The page shows one
 * tab's cards at a time, so `tab` says which tab this text is from; without
 * it the cards take the only tab with containers in it. Booking copy
 * (reservations, Submit) is never read as a card.
 */
export function parseShipcsxLookupText(text: string, tab?: Exclude<CsxLookupTab, 'NOT_FOUND'> | null): CsxLookupParseResult {
  const source = text ?? ''
  const tabCounts: CsxLookupParseResult['tabCounts'] = {}

  for (const match of source.matchAll(/(NOTIFIED|ENROUTE|EN-ROUTE|IN-GATE|IN GATE|OTHERS)\s*\((\d+)\)/gi)) {
    const found = shipcsxTabFromHeading(match[1] ?? '')
    if (found) tabCounts[found] = Number(match[2])
  }
  const asOf = source.match(/As of\s+([^\n]+)/i)?.[1]?.trim() ?? null
  const withCards = Object.entries(tabCounts).filter(([, count]) => (count ?? 0) > 0)
  const pageTab: CsxLookupTab = tab ?? (withCards.length === 1 ? withCards[0]![0] as CsxLookupTab : 'OTHERS')

  const cards: CsxLookupCard[] = []
  for (const block of source.split(/(?=\b[A-Z]{4}\s?\d{6,7}\b)/g)) {
    const equipMatch = block.match(/^([A-Z]{4})\s?(\d{6,7})\b/)
    if (!equipMatch) continue
    const equipmentNumber = compactEquip(`${equipMatch[1]}${equipMatch[2]}`)
    const upper = block.toUpperCase()
    if (!/WAYBILL|READINESS|LOAD \/ EMPTY|LOAD\/EMPTY/.test(upper)) continue

    const fields: Record<string, string> = {}
    for (const label of CARD_LABELS) {
      const value = labelValue(block, label)
      if (value) fields[label] = value
    }
    cards.push({
      equipmentNumber,
      loadEmpty: fields['Load / Empty'] ?? null,
      waybillDate: fields['Waybill Date'] ?? null,
      inGateReadiness: fields['In-Gate Readiness'] ?? null,
      gateWindow: fields['Gate Window'] ?? null,
      resultTab: pageTab,
      fields,
    })
  }

  return { cards, tabCounts, asOf }
}

/** The card for a container. ShipCSX shows the initial and serial, sometimes without the check digit. */
export function matchLookupCard(cards: CsxLookupCard[], equipmentNumber: string): CsxLookupCard | null {
  const needle = compactEquip(equipmentNumber).slice(0, 10)
  return cards.find(card => compactEquip(card.equipmentNumber).slice(0, 10) === needle) ?? null
}


/** How ShipCSX wants a container: initial and serial as one string, no check digit (TTRU485022). */
export function shipcsxEquipment(equipmentNumber: string): string | null {
  const match = compactEquip(equipmentNumber).match(/^[A-Z]{4}\d{6}/)
  return match ? match[0] : null
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
