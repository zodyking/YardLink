import { describe, expect, it } from 'vitest'
import {
  driverTimelineTitle,
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
    expect(driverTimelineTitle('CHASSIS_ATTACH')).toBe('Container placed on chassis')
    expect(driverTimelineTitle('CHASSIS_DETACH')).toBe('Container removed from chassis')
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
