/**
 * Container duty cycles.
 *
 * A duty cycle is one working life of a physical container: it opens when the
 * box leaves a marine terminal or rail yard (or first shows up in the company
 * network) and completes when the box is returned to a marine terminal or
 * rail yard. The same container number comes back many times, so the cycle —
 * not the number — is what history hangs from. Every cycle has its own id and
 * a per-container sequence, and a completed cycle is never reopened.
 *
 * This module is the single rule set. The server applies {@link cycleStep} as
 * each event is recorded; {@link replayDutyCycles} runs the same rules over
 * stored history to backfill records created before cycles existed.
 * Chassis keep one continuous history of their own — {@link chassisPairings}
 * folds it into "which box, on which cycle, from when to when".
 */

import type { EventType, LocationType } from './domain'
import { isServiceTerminus } from './service-life'

export const DUTY_CYCLE_STATUSES = ['ACTIVE', 'COMPLETED', 'VOIDED'] as const
export type DutyCycleStatus = (typeof DUTY_CYCLE_STATUSES)[number]

export const DUTY_CYCLE_STATUS_LABELS: Record<DutyCycleStatus, string> = {
  ACTIVE: 'Active',
  COMPLETED: 'Completed',
  VOIDED: 'Cancelled',
}

/** How an event relates to the container's cycles. */
export interface CycleStep {
  /** Close a cycle that was left open before opening the next one. */
  closeStale: boolean
  /** Open a new cycle with this event as its first entry. */
  open: boolean
  /** Which cycle the event is filed under. */
  attach: 'ACTIVE' | 'LATEST' | 'NONE'
  /** This event returns the box to a terminal and completes the cycle. */
  complete: boolean
  /** The pickup that opened the cycle was cancelled — the cycle never happened. */
  void: boolean
}

export interface CycleStepInput {
  eventType: EventType
  /** Type of the location the event happened at, when known. */
  locationType: LocationType | null | undefined
  hasActiveCycle: boolean
  /** Trip on the event, and the trip that opened the active cycle. */
  tripId?: string | null
  activeCycleStartTripId?: string | null
}

/** Events that follow a movement and belong with whatever cycle just ran. */
const TRAILING_EVENTS: ReadonlySet<EventType> = new Set<EventType>([
  'RELEASED',
  'CHASSIS_DETACH',
  'CORRECTION',
  'DOCUMENT_ADDED',
  'DAMAGE_REPORTED',
  'STATUS_CHANGE',
])

/** Events that put a box on a site without a driver trip. */
const SITE_EVENTS: ReadonlySet<EventType> = new Set<EventType>(['ACTIVATED', 'YARD_MOVE'])

export function cycleStep(input: CycleStepInput): CycleStep {
  const atTerminus = isServiceTerminus(input.locationType)
  const step: CycleStep = { closeStale: false, open: false, attach: 'NONE', complete: false, void: false }

  switch (input.eventType) {
    case 'PICKUP_CONFIRMED': {
      // A box collected from a terminal cannot still be on its previous cycle:
      // it must have been returned without the drop-off being recorded.
      const stale = input.hasActiveCycle && atTerminus && input.activeCycleStartTripId !== input.tripId
      step.closeStale = stale
      step.open = !input.hasActiveCycle || stale
      step.attach = 'ACTIVE'
      return step
    }
    case 'DROPOFF_CONFIRMED':
      step.open = !input.hasActiveCycle
      step.attach = 'ACTIVE'
      step.complete = atTerminus
      return step
    case 'PICKUP_CANCELLED':
      step.attach = input.hasActiveCycle ? 'ACTIVE' : 'NONE'
      step.void = Boolean(
        input.hasActiveCycle
        && input.tripId
        && input.activeCycleStartTripId === input.tripId,
      )
      return step
    default:
      break
  }

  if (SITE_EVENTS.has(input.eventType)) {
    if (atTerminus) {
      // Staged at a terminal: either it just came back, or it has not left yet.
      step.attach = input.hasActiveCycle ? 'ACTIVE' : 'NONE'
      step.complete = input.hasActiveCycle
      return step
    }
    step.open = !input.hasActiveCycle
    step.attach = 'ACTIVE'
    return step
  }

  if (input.hasActiveCycle) {
    step.attach = 'ACTIVE'
    return step
  }
  step.attach = TRAILING_EVENTS.has(input.eventType) ? 'LATEST' : 'NONE'
  return step
}

/* ------------------------------------------------------------------ */
/* Replay — used for backfill and as an executable spec in tests.      */
/* ------------------------------------------------------------------ */

export interface ReplayEvent {
  id: string
  eventType: EventType
  occurredAt: Date | string
  tripId?: string | null
  locationId?: string | null
  locationType?: LocationType | null
}

export interface ReplayedCycle {
  /** 1-based, per container. */
  sequence: number
  status: DutyCycleStatus
  startedAt: Date | string
  startEventId: string
  startLocationId: string | null
  startTripId: string | null
  completedAt: Date | string | null
  endEventId: string | null
  endLocationId: string | null
  endTripId: string | null
  /** True when the cycle was closed because the next terminal pickup proved it ended. */
  closedByNextPickup: boolean
  eventIds: string[]
}

function time(value: Date | string): number {
  const stamp = value instanceof Date ? value.getTime() : new Date(value).getTime()
  return Number.isNaN(stamp) ? 0 : stamp
}

/**
 * One driver action writes several events with the same timestamp. This is
 * the order they happen in, used to break the tie.
 */
const SAME_MOMENT_RANK: Partial<Record<EventType, number>> = {
  PICKUP_STARTED: 0,
  PICKUP_CONFIRMED: 1,
  CHASSIS_ATTACH: 2,
  DROPOFF_STARTED: 3,
  DROPOFF_CONFIRMED: 4,
  CHASSIS_DETACH: 5,
  RELEASED: 6,
}

function chronological<T extends { eventType: EventType, occurredAt: Date | string }>(events: T[]): T[] {
  return events
    .map((event, index) => ({ event, index }))
    .sort((a, b) =>
      time(a.event.occurredAt) - time(b.event.occurredAt)
      || (SAME_MOMENT_RANK[a.event.eventType] ?? 2.5) - (SAME_MOMENT_RANK[b.event.eventType] ?? 2.5)
      || a.index - b.index,
    )
    .map(row => row.event)
}

/**
 * Rebuild one container's cycles from its events. Input order is preserved
 * for events that share a timestamp, so pass rows in stored order.
 */
export function replayDutyCycles(events: ReplayEvent[]): ReplayedCycle[] {
  const ordered = chronological(events)

  const cycles: ReplayedCycle[] = []
  let active: ReplayedCycle | null = null
  /** Trip events seen before their cycle opened (PICKUP_STARTED, early hang). */
  const pendingByTrip = new Map<string, string[]>()

  const openCycle = (event: ReplayEvent): ReplayedCycle => {
    const cycle: ReplayedCycle = {
      sequence: cycles.length + 1,
      status: 'ACTIVE',
      startedAt: event.occurredAt,
      startEventId: event.id,
      startLocationId: event.locationId ?? null,
      startTripId: event.tripId ?? null,
      completedAt: null,
      endEventId: null,
      endLocationId: null,
      endTripId: null,
      closedByNextPickup: false,
      eventIds: [],
    }
    cycles.push(cycle)
    if (event.tripId) {
      const early = pendingByTrip.get(event.tripId)
      if (early) {
        cycle.eventIds.push(...early)
        pendingByTrip.delete(event.tripId)
      }
    }
    return cycle
  }

  for (const event of ordered) {
    const step = cycleStep({
      eventType: event.eventType,
      locationType: event.locationType,
      hasActiveCycle: Boolean(active),
      tripId: event.tripId,
      activeCycleStartTripId: active?.startTripId,
    })

    if (step.closeStale && active) {
      active.status = 'COMPLETED'
      active.completedAt = event.occurredAt
      active.endLocationId = event.locationId ?? null
      active.closedByNextPickup = true
      active = null
    }
    if (step.open) active = openCycle(event)

    if (step.attach === 'ACTIVE' && active) {
      active.eventIds.push(event.id)
    }
    else if (step.attach === 'LATEST' && cycles.length) {
      cycles[cycles.length - 1]!.eventIds.push(event.id)
    }
    else if (event.tripId) {
      const early = pendingByTrip.get(event.tripId) ?? []
      early.push(event.id)
      pendingByTrip.set(event.tripId, early)
    }

    if (step.void && active) {
      active.status = 'VOIDED'
      active.completedAt = event.occurredAt
      active.endEventId = event.id
      active = null
    }
    else if (step.complete && active) {
      active.status = 'COMPLETED'
      active.completedAt = event.occurredAt
      active.endEventId = event.id
      active.endLocationId = event.locationId ?? null
      active.endTripId = event.tripId ?? null
      active = null
    }
  }

  return cycles
}

/* ------------------------------------------------------------------ */
/* Chassis pairings                                                    */
/* ------------------------------------------------------------------ */

export interface ChassisHistoryEvent {
  id: string
  eventType: EventType
  occurredAt: Date | string
  containerId?: string | null
  dutyCycleId?: string | null
  tripId?: string | null
  locationId?: string | null
  actorDriverId?: string | null
}

export interface ChassisPairing {
  containerId: string
  dutyCycleId: string | null
  pairedAt: Date | string
  pairedEventId: string
  pairedLocationId: string | null
  pairedByDriverId: string | null
  separatedAt: Date | string | null
  separatedEventId: string | null
  separatedLocationId: string | null
  separatedByDriverId: string | null
}

/**
 * Fold one chassis's events into container pairings, oldest first. A pairing
 * opens the first time the chassis is seen under a box (hang, or a pickup that
 * already had the box on it) and closes on the detach — or when the chassis
 * turns up under a different box or moves bare, which proves the old pairing
 * ended even if the detach was never recorded. Each pairing carries the
 * container's duty cycle so two visits by the same box stay separate.
 */
export function chassisPairings(events: ChassisHistoryEvent[]): ChassisPairing[] {
  const ordered = chronological(events)

  const pairings: ChassisPairing[] = []
  let open: ChassisPairing | null = null

  const close = (event: ChassisHistoryEvent) => {
    if (!open) return
    open.separatedAt = event.occurredAt
    open.separatedEventId = event.id
    open.separatedLocationId = event.locationId ?? null
    open.separatedByDriverId = event.actorDriverId ?? null
    open = null
  }

  for (const event of ordered) {
    const pairs = event.eventType === 'CHASSIS_ATTACH'
      || event.eventType === 'PICKUP_CONFIRMED'
      || event.eventType === 'DROPOFF_CONFIRMED'
      || event.eventType === 'ACTIVATED'
      || event.eventType === 'YARD_MOVE'

    if (event.eventType === 'CHASSIS_DETACH') {
      if (open && (!event.containerId || event.containerId === open.containerId)) close(event)
      continue
    }
    if (!pairs) continue

    if (!event.containerId) {
      // The chassis is moving bare, so whatever was on it is gone.
      if (event.eventType === 'PICKUP_CONFIRMED') close(event)
      continue
    }

    if (open && open.containerId === event.containerId) {
      if (!open.dutyCycleId && event.dutyCycleId) open.dutyCycleId = event.dutyCycleId
      if (!open.dutyCycleId || !event.dutyCycleId || open.dutyCycleId === event.dutyCycleId) continue
    }
    close(event)
    open = {
      containerId: event.containerId,
      dutyCycleId: event.dutyCycleId ?? null,
      pairedAt: event.occurredAt,
      pairedEventId: event.id,
      pairedLocationId: event.locationId ?? null,
      pairedByDriverId: event.actorDriverId ?? null,
      separatedAt: null,
      separatedEventId: null,
      separatedLocationId: null,
      separatedByDriverId: null,
    }
    pairings.push(open)
  }

  return pairings
}

/** `Cycle 3` style label used wherever a cycle is named. */
export function dutyCycleLabel(sequence: number): string {
  return `Cycle ${sequence}`
}
