import { describe, expect, it } from 'vitest'

import type { EventType, LocationType } from '../shared/utils/domain'
import { chassisPairings, cycleStep, replayDutyCycles } from '../shared/utils/duty-cycle'
import type { ChassisHistoryEvent, ReplayEvent } from '../shared/utils/duty-cycle'

let counter = 0
function ev(
  eventType: EventType,
  occurredAt: string,
  locationType: LocationType | null,
  tripId: string | null = null,
  locationId: string | null = null,
): ReplayEvent {
  counter += 1
  return { id: `e${counter}`, eventType, occurredAt, locationType, tripId, locationId }
}

describe('cycleStep', () => {
  it('opens a cycle on the first confirmed pickup', () => {
    const step = cycleStep({ eventType: 'PICKUP_CONFIRMED', locationType: 'MARINE_TERMINAL', hasActiveCycle: false })
    expect(step.open).toBe(true)
    expect(step.attach).toBe('ACTIVE')
    expect(step.complete).toBe(false)
  })

  it('keeps the cycle open through customer and company-yard stops', () => {
    for (const type of ['CUSTOMER', 'COMPANY_YARD'] as const) {
      const step = cycleStep({ eventType: 'DROPOFF_CONFIRMED', locationType: type, hasActiveCycle: true })
      expect(step.complete).toBe(false)
      expect(step.open).toBe(false)
    }
  })

  it('completes the cycle only on return to a marine terminal or rail yard', () => {
    for (const type of ['MARINE_TERMINAL', 'RAIL_TERMINAL'] as const) {
      expect(cycleStep({ eventType: 'DROPOFF_CONFIRMED', locationType: type, hasActiveCycle: true }).complete).toBe(true)
    }
  })

  it('files the release and detach that follow a return under the finished cycle', () => {
    expect(cycleStep({ eventType: 'RELEASED', locationType: 'RAIL_TERMINAL', hasActiveCycle: false }).attach).toBe('LATEST')
    expect(cycleStep({ eventType: 'CHASSIS_DETACH', locationType: 'RAIL_TERMINAL', hasActiveCycle: false }).attach).toBe('LATEST')
  })

  it('does not open a cycle for a box staged at a terminal', () => {
    const step = cycleStep({ eventType: 'ACTIVATED', locationType: 'RAIL_TERMINAL', hasActiveCycle: false })
    expect(step.open).toBe(false)
    expect(step.attach).toBe('NONE')
  })

  it('opens a cycle for a box first recorded at a yard or customer', () => {
    expect(cycleStep({ eventType: 'ACTIVATED', locationType: 'COMPANY_YARD', hasActiveCycle: false }).open).toBe(true)
    expect(cycleStep({ eventType: 'YARD_MOVE', locationType: 'CUSTOMER', hasActiveCycle: false }).open).toBe(true)
  })

  it('voids a cycle only when the pickup that opened it is cancelled', () => {
    expect(cycleStep({ eventType: 'PICKUP_CANCELLED', locationType: null, hasActiveCycle: true, tripId: 't1', activeCycleStartTripId: 't1' }).void).toBe(true)
    expect(cycleStep({ eventType: 'PICKUP_CANCELLED', locationType: null, hasActiveCycle: true, tripId: 't2', activeCycleStartTripId: 't1' }).void).toBe(false)
  })

  it('closes a cycle left open when the box is next collected from a terminal', () => {
    const step = cycleStep({ eventType: 'PICKUP_CONFIRMED', locationType: 'MARINE_TERMINAL', hasActiveCycle: true, tripId: 't9', activeCycleStartTripId: 't1' })
    expect(step.closeStale).toBe(true)
    expect(step.open).toBe(true)
  })
})

describe('replayDutyCycles', () => {
  it('builds one cycle from terminal pickup to terminal return', () => {
    const events = [
      ev('PICKUP_STARTED', '2026-01-05T12:00:00Z', 'MARINE_TERMINAL', 't1', 'port'),
      ev('PICKUP_CONFIRMED', '2026-01-05T12:10:00Z', 'MARINE_TERMINAL', 't1', 'port'),
      ev('CHASSIS_ATTACH', '2026-01-05T12:10:00Z', 'MARINE_TERMINAL', 't1', 'port'),
      ev('DROPOFF_CONFIRMED', '2026-01-05T15:00:00Z', 'CUSTOMER', 't1', 'cust'),
      ev('CHASSIS_DETACH', '2026-01-05T15:00:00Z', 'CUSTOMER', 't1', 'cust'),
      ev('PICKUP_CONFIRMED', '2026-01-08T10:00:00Z', 'CUSTOMER', 't2', 'cust'),
      ev('DROPOFF_CONFIRMED', '2026-01-08T13:00:00Z', 'RAIL_TERMINAL', 't2', 'rail'),
      ev('RELEASED', '2026-01-08T13:00:00Z', 'RAIL_TERMINAL', 't2', 'rail'),
    ]
    const cycles = replayDutyCycles(events)
    expect(cycles).toHaveLength(1)
    expect(cycles[0]!.status).toBe('COMPLETED')
    expect(cycles[0]!.startLocationId).toBe('port')
    expect(cycles[0]!.endLocationId).toBe('rail')
    expect(cycles[0]!.startTripId).toBe('t1')
    expect(cycles[0]!.endTripId).toBe('t2')
    // Every event, including the pickup start that preceded the cycle, is filed.
    expect(cycles[0]!.eventIds).toHaveLength(events.length)
  })

  it('gives a reused container number a new cycle and leaves the old one untouched', () => {
    const first = [
      ev('PICKUP_CONFIRMED', '2026-01-05T12:00:00Z', 'MARINE_TERMINAL', 't1', 'port'),
      ev('DROPOFF_CONFIRMED', '2026-01-06T12:00:00Z', 'MARINE_TERMINAL', 't1', 'port'),
    ]
    const before = replayDutyCycles(first)
    const second = [
      ...first,
      ev('PICKUP_CONFIRMED', '2026-03-01T12:00:00Z', 'RAIL_TERMINAL', 't7', 'rail'),
      ev('DROPOFF_CONFIRMED', '2026-03-01T16:00:00Z', 'COMPANY_YARD', 't7', 'yard'),
    ]
    const after = replayDutyCycles(second)
    expect(after).toHaveLength(2)
    expect(after[0]).toEqual(before[0])
    expect(after[1]!.sequence).toBe(2)
    expect(after[1]!.status).toBe('ACTIVE')
    expect(after[1]!.startLocationId).toBe('rail')
    // No event is filed under two cycles.
    const all = after.flatMap(cycle => cycle.eventIds)
    expect(new Set(all).size).toBe(all.length)
  })

  it('never has two active cycles for one container', () => {
    const cycles = replayDutyCycles([
      ev('PICKUP_CONFIRMED', '2026-01-01T12:00:00Z', 'MARINE_TERMINAL', 't1', 'port'),
      ev('DROPOFF_CONFIRMED', '2026-01-01T15:00:00Z', 'CUSTOMER', 't1', 'cust'),
      // The return was never recorded; the box is collected at the port again.
      ev('PICKUP_CONFIRMED', '2026-02-01T12:00:00Z', 'MARINE_TERMINAL', 't2', 'port'),
    ])
    expect(cycles).toHaveLength(2)
    expect(cycles.filter(cycle => cycle.status === 'ACTIVE')).toHaveLength(1)
    expect(cycles[0]!.status).toBe('COMPLETED')
    expect(cycles[0]!.closedByNextPickup).toBe(true)
  })

  it('voids a cycle whose opening pickup was cancelled', () => {
    const cycles = replayDutyCycles([
      ev('PICKUP_CONFIRMED', '2026-01-01T12:00:00Z', 'MARINE_TERMINAL', 't1', 'port'),
      ev('PICKUP_CANCELLED', '2026-01-01T12:05:00Z', null, 't1'),
      ev('PICKUP_CONFIRMED', '2026-01-02T12:00:00Z', 'MARINE_TERMINAL', 't2', 'port'),
    ])
    expect(cycles.map(cycle => cycle.status)).toEqual(['VOIDED', 'ACTIVE'])
  })

  it('orders same-moment events the way the action happened', () => {
    const cycles = replayDutyCycles([
      ev('CHASSIS_ATTACH', '2026-01-01T12:00:00Z', 'MARINE_TERMINAL', 't1', 'port'),
      ev('PICKUP_CONFIRMED', '2026-01-01T12:00:00Z', 'MARINE_TERMINAL', 't1', 'port'),
    ])
    expect(cycles).toHaveLength(1)
    expect(cycles[0]!.eventIds).toHaveLength(2)
  })
})

describe('chassisPairings', () => {
  function ce(
    eventType: EventType,
    occurredAt: string,
    containerId: string | null,
    dutyCycleId: string | null,
    driver = 'd1',
    locationId = 'loc',
  ): ChassisHistoryEvent {
    counter += 1
    return { id: `c${counter}`, eventType, occurredAt, containerId, dutyCycleId, actorDriverId: driver, locationId }
  }

  it('tracks a chassis across several containers without merging them', () => {
    const pairings = chassisPairings([
      ce('PICKUP_CONFIRMED', '2026-01-01T10:00:00Z', 'boxA', 'cycA1', 'd1', 'port'),
      ce('CHASSIS_ATTACH', '2026-01-01T10:00:00Z', 'boxA', 'cycA1', 'd1', 'port'),
      ce('DROPOFF_CONFIRMED', '2026-01-01T14:00:00Z', 'boxA', 'cycA1', 'd1', 'cust'),
      ce('CHASSIS_DETACH', '2026-01-01T14:00:00Z', 'boxA', 'cycA1', 'd1', 'cust'),
      // Driver keeps the chassis and moves it bare.
      ce('PICKUP_CONFIRMED', '2026-01-01T14:05:00Z', null, null, 'd1', 'cust'),
      ce('DROPOFF_CONFIRMED', '2026-01-01T15:00:00Z', null, null, 'd1', 'yard'),
      ce('PICKUP_CONFIRMED', '2026-01-02T09:00:00Z', 'boxB', 'cycB1', 'd2', 'yard'),
      ce('CHASSIS_ATTACH', '2026-01-02T09:00:00Z', 'boxB', 'cycB1', 'd2', 'yard'),
    ])
    expect(pairings).toHaveLength(2)
    expect(pairings[0]).toMatchObject({ containerId: 'boxA', dutyCycleId: 'cycA1', pairedLocationId: 'port', separatedLocationId: 'cust', separatedByDriverId: 'd1' })
    expect(pairings[1]).toMatchObject({ containerId: 'boxB', dutyCycleId: 'cycB1', pairedByDriverId: 'd2', separatedAt: null })
  })

  it('separates two visits by the same container on different duty cycles', () => {
    const pairings = chassisPairings([
      ce('PICKUP_CONFIRMED', '2026-01-01T10:00:00Z', 'boxA', 'cycA1'),
      ce('CHASSIS_DETACH', '2026-01-02T10:00:00Z', 'boxA', 'cycA1'),
      ce('PICKUP_CONFIRMED', '2026-04-01T10:00:00Z', 'boxA', 'cycA2'),
    ])
    expect(pairings.map(pairing => pairing.dutyCycleId)).toEqual(['cycA1', 'cycA2'])
  })

  it('closes a pairing when the chassis shows up under another box with no detach recorded', () => {
    const pairings = chassisPairings([
      ce('PICKUP_CONFIRMED', '2026-01-01T10:00:00Z', 'boxA', 'cycA1'),
      ce('PICKUP_CONFIRMED', '2026-01-03T10:00:00Z', 'boxB', 'cycB1'),
    ])
    expect(pairings).toHaveLength(2)
    expect(pairings[0]!.separatedAt).toBe('2026-01-03T10:00:00Z')
  })
})
