import { describe, expect, it } from 'vitest'
import {
  chunkShipcsxEquipment,
  matchLookupCard,
  parseShipcsxLookupText,
  shipcsxEquipment,
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

  it('reads every card on the page as ShipCSX lays it out, label above value', () => {
    const page = [
      'Shipment Lookup Results', 'As of 20:23 on 11/25/26', 'Modify Search', 'North Bergen',
      'NOTIFIED (0)', 'ENROUTE (0)', 'IN-GATE (2)', 'OTHERS (0)',
      'TTRU 485022', 'Load / Empty', 'Load', 'Waybill Date', '11/24/26',
      'In-Gate Readiness', 'Reservation Required', 'Gate Window', 'N/A', 'Add Reservation',
      'BSIU 819372', 'Load / Empty', 'Load', 'Waybill Date', '11/23/26',
      'In-Gate Readiness', 'Equipment In-Gated', 'Gate Window', 'N/A',
    ].join('\n')
    const parsed = parseShipcsxLookupText(page)
    expect(parsed.asOf).toBe('20:23 on 11/25/26')
    expect(parsed.cards.map(card => card.equipmentNumber)).toEqual(['TTRU485022', 'BSIU819372'])
    expect(matchLookupCard(parsed.cards, 'TTRU4850221')?.inGateReadiness).toBe('Reservation Required')
    expect(matchLookupCard(parsed.cards, 'BSIU8193726')?.inGateReadiness).toBe('Equipment In-Gated')
    expect(parsed.cards[0]?.fields['Waybill Date']).toBe('11/24/26')
    expect(parsed.cards[0]?.resultTab).toBe('IN_GATE')
  })

  it('files cards under the tab they were read from', () => {
    const parsed = parseShipcsxLookupText('NOTIFIED (1)\nIN-GATE (1)\nKOSU 495338\nWaybill Date\n09/03/26', 'NOTIFIED')
    expect(parsed.cards[0]?.resultTab).toBe('NOTIFIED')
  })

  it('ignores reservation success copy', () => {
    const parsed = parseShipcsxLookupText('Reservation Successful\nReservation ID: NBDLNQ\nSubmit')
    expect(parsed.cards).toEqual([])
  })

  it('batches equipment by the search size', () => {
    expect(chunkShipcsxEquipment(['a', 'b', 'c', 'd'], 3).map(batch => batch.length)).toEqual([3, 1])
  })
})

describe('ShipCSX equipment string', () => {
  it('gives initial and serial as one string, no check digit', () => {
    expect(shipcsxEquipment('KOSU496803-5')).toBe('KOSU496803')
    expect(shipcsxEquipment('KOSU4968035')).toBe('KOSU496803')
    expect(shipcsxEquipment('kosu 496803')).toBe('KOSU496803')
    expect(shipcsxEquipment('ABC')).toBeNull()
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
