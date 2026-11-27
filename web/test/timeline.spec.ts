import { describe, expect, it } from 'vitest'
import {
  driverTimelineTitle,
  equipmentEventTitle,
  isDriverTimelineEvent,
  timelineNote,
  visibleTimelineEntries,
} from '../shared/utils/timeline'

describe('driver timeline', () => {
  it('hides started, cancelled, and released rows', () => {
    expect(isDriverTimelineEvent('PICKUP_STARTED')).toBe(false)
    expect(isDriverTimelineEvent('PICKUP_CANCELLED')).toBe(false)
    expect(isDriverTimelineEvent('RELEASED')).toBe(false)
    expect(isDriverTimelineEvent('CORRECTION')).toBe(false)
    expect(isDriverTimelineEvent('PICKUP_CONFIRMED')).toBe(true)
    expect(isDriverTimelineEvent('CHASSIS_ATTACH')).toBe(true)
  })

  it('uses equipment language for hang and unhang', () => {
    expect(driverTimelineTitle('PICKUP_CONFIRMED')).toBe('Picked up')
    expect(driverTimelineTitle('DROPOFF_CONFIRMED')).toBe('Dropped off')
    expect(driverTimelineTitle('CHASSIS_ATTACH')).toBe('Placed on chassis')
    expect(driverTimelineTitle('CHASSIS_DETACH')).toBe('Removed from chassis')
    expect(driverTimelineTitle('CHASSIS_ATTACH', undefined, 'chassis')).toBe('Container placed on chassis')
    expect(driverTimelineTitle('CHASSIS_DETACH', undefined, 'chassis')).toBe('Container removed from chassis')
  })

  it('words a container hung on a chassis the driver already had as one step', () => {
    const hung = {
      id: 'pick',
      eventType: 'PICKUP_CONFIRMED' as const,
      containerId: 'c1',
      chassisId: 'ch1',
      chassisNumber: 'SLSZ123456',
      payload: { attachedToBareChassis: true },
    }
    expect(driverTimelineTitle('PICKUP_CONFIRMED', hung)).toBe('Picked up and placed on chassis')
    expect(driverTimelineTitle('PICKUP_CONFIRMED', hung, 'chassis')).toBe('Container picked up and placed on chassis')
  })

  it('drops the duplicate hang recorded with that pickup, and only that one', () => {
    const at = '2026-11-01T10:00:00.000Z'
    const base = { containerId: 'c1', chassisId: 'ch1', tripId: 't1' }
    const rows = visibleTimelineEntries([
      { id: 'pick', eventType: 'PICKUP_CONFIRMED' as const, occurredAt: at, payload: { attachedToBareChassis: true }, ...base },
      { id: 'hang', eventType: 'CHASSIS_ATTACH' as const, occurredAt: at, ...base },
      { id: 'later', eventType: 'CHASSIS_ATTACH' as const, occurredAt: '2026-11-02T10:00:00.000Z', ...base },
    ])
    expect(rows.map(row => row.id)).toEqual(['pick', 'later'])
  })

  it('words the other rows the same everywhere', () => {
    expect(equipmentEventTitle('RELEASED')).toBe('Returned and released')
    expect(equipmentEventTitle('ACTIVATED')).toBe('Added to the yard')
    expect(equipmentEventTitle('YARD_MOVE')).toBe('Moved')
  })

  it('says both pieces moved when a pickup names the chassis', () => {
    const pickup = { id: 'pick', eventType: 'PICKUP_CONFIRMED' as const, chassisNumber: 'SLSZ123456' }
    expect(driverTimelineTitle('PICKUP_CONFIRMED', pickup)).toBe('Container and chassis picked up')
    expect(driverTimelineTitle('PICKUP_CONFIRMED', { ...pickup, payload: { kind: 'BARE_CHASSIS' } }))
      .toBe('Chassis picked up')
    const dropped = {
      id: 'drop',
      eventType: 'DROPOFF_CONFIRMED' as const,
      chassisNumber: 'SLSZ123456',
      payload: { retainChassis: true },
    }
    expect(driverTimelineTitle('DROPOFF_CONFIRMED', dropped)).toBe('Container and chassis dropped off')
    expect(driverTimelineTitle('DROPOFF_CONFIRMED', { ...dropped, payload: { retainChassis: false } }))
      .toBe('Dropped off')
  })

  it('never invents a hang from a pickup that only names the chassis', () => {
    const rows = visibleTimelineEntries([
      { id: 'drop', eventType: 'DROPOFF_CONFIRMED' as const, payload: { retainChassis: false } },
      { id: 'pick', eventType: 'PICKUP_CONFIRMED' as const, chassisNumber: 'SLSZ123456' },
      { id: 'start', eventType: 'PICKUP_STARTED' as const },
      { id: 'cancel', eventType: 'PICKUP_CANCELLED' as const },
    ])
    expect(rows.map(row => row.eventType)).toEqual(['DROPOFF_CONFIRMED', 'PICKUP_CONFIRMED'])
  })

  it('keeps a stored hang or unhang, which is a real one', () => {
    const rows = visibleTimelineEntries([
      { id: 'pick', eventType: 'PICKUP_CONFIRMED' as const, chassisNumber: 'SLSZ123456' },
      { id: 'hang', eventType: 'CHASSIS_ATTACH' as const, chassisNumber: 'SLSZ123456' },
    ])
    expect(rows.map(row => row.id)).toEqual(['pick', 'hang'])
  })

  it('hides system notes', () => {
    expect(timelineNote('Driver cancelled from Home.')).toBeNull()
    expect(timelineNote('Final release from the tracked network.')).toBeNull()
    expect(timelineNote('Gate was closed.')).toBe('Gate was closed.')
  })
})
