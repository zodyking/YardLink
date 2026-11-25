import { describe, expect, it } from 'vitest'
import {
  shipcsxEquipmentParts,
  shipcsxTerminalName,
  SHIPCSX_TERMINALS,
} from '../shared/utils/csx-lookup'

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
