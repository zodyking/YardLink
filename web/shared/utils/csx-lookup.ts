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

/** ShipCSX's lookup asks for a 4-letter initial and 6-digit serial (no check digit). */
export interface ShipcsxEquipmentParts {
  initial: string
  number: string
}

export function shipcsxEquipmentParts(equipmentNumber: string): ShipcsxEquipmentParts | null {
  const compact = equipmentNumber.toUpperCase().replace(/[^A-Z0-9]/g, '')
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
