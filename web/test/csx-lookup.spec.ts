import { describe, expect, it } from 'vitest'
import {
  chunkShipcsxEquipment,
  matchLookupCard,
  parseShipcsxLookupText,
  shipcsxEquipmentParts,
  shipcsxTerminalName,
  SHIPCSX_TERMINALS,
} from '../shared/utils/csx-lookup'

const RESULTS = `
Shipment Lookup Results
As of 17:03 on 09/03/26
NOTIFIED (0) ENROUTE (0) IN-GATE (1) OTHERS (0)
KOSU 495338
Load / Empty: Load
Waybill Date: 09/03/26
In-Gate Readiness: Ready to In-Gate
Gate Window: Expires at 09/03 23:59
`

describe('ShipCSX lookup parse', () => {
  it('reads the in-gate card from results text', () => {
    const parsed = parseShipcsxLookupText(RESULTS)
    expect(parsed.tabCounts.IN_GATE).toBe(1)
    const card = matchLookupCard(parsed.cards, 'KOSU495338')
    expect(card?.resultTab).toBe('IN_GATE')
    expect(card?.loadEmpty).toBe('Load')
    expect(card?.waybillDate).toBe('09/03/26')
    expect(card?.inGateReadiness).toBe('Ready to In-Gate')
    expect(card?.gateWindow).toContain('09/03 23:59')
  })

  it('matches our full number, check digit and all, to the card', () => {
    const parsed = parseShipcsxLookupText(RESULTS)
    expect(matchLookupCard(parsed.cards, 'KOSU495338-2')?.equipmentNumber).toBe('KOSU495338')
    expect(matchLookupCard(parsed.cards, 'TTRU4850221')).toBeNull()
  })

  it('ignores reservation success copy', () => {
    const parsed = parseShipcsxLookupText('Reservation Successful\nReservation ID: NBDLNQ\nSubmit')
    expect(parsed.cards).toEqual([])
  })

  it('batches equipment three at a time', () => {
    expect(chunkShipcsxEquipment(['a', 'b', 'c', 'd']).map(batch => batch.length)).toEqual([3, 1])
  })
})

describe('ShipCSX equipment parts', () => {
  it('splits ISO numbers into the 4-letter initial and 6-digit serial', () => {
    expect(shipcsxEquipmentParts('KOSU496803-5')).toEqual({ initial: 'KOSU', number: '496803' })
    expect(shipcsxEquipmentParts('KOSU4968035')).toEqual({ initial: 'KOSU', number: '496803' })
    expect(shipcsxEquipmentParts('kosu 496803')).toEqual({ initial: 'KOSU', number: '496803' })
    expect(shipcsxEquipmentParts('ABC')).toBeNull()
  })
})

describe('ShipCSX terminal names', () => {
  it('lists the five CSX facilities', () => {
    expect([...SHIPCSX_TERMINALS]).toEqual([
      'North Bergen',
      'Little Ferry',
      'South Kearny',
      'Elizabeth',
      'Newark',
    ])
  })

  it('maps a stored name onto one facility, or none', () => {
    expect(shipcsxTerminalName('Little Ferry')).toBe('Little Ferry')
    expect(shipcsxTerminalName('  north  bergen ')).toBe('North Bergen')
    expect(shipcsxTerminalName('CSX North Bergen Intermodal')).toBe('North Bergen')
    expect(shipcsxTerminalName('NJ Yard')).toBeNull()
    expect(shipcsxTerminalName('')).toBeNull()
  })
})
