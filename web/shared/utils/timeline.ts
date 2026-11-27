import type { EventType } from './domain'

/** Events a driver should see on trip and equipment history. */
export const DRIVER_TIMELINE_EVENT_TYPES = [
  'PICKUP_CONFIRMED',
  'DROPOFF_CONFIRMED',
  'CHASSIS_ATTACH',
  'CHASSIS_DETACH',
] as const

export type DriverTimelineEventType = (typeof DRIVER_TIMELINE_EVENT_TYPES)[number]

export type TimelineNodeKind = 'pickup' | 'dropoff' | 'attach' | 'detach'

export function isDriverTimelineEvent(eventType: EventType): eventType is DriverTimelineEventType {
  return (DRIVER_TIMELINE_EVENT_TYPES as readonly string[]).includes(eventType)
}

/** Whose history the row is on: the words differ for the box, the chassis and the trip. */
export type TimelineSubject = 'container' | 'chassis' | 'trip'

/**
 * What happened, in the driver's words, for one row of equipment history.
 *
 * - A bare chassis moving says "Chassis ...", never "Container ...".
 * - A container hung on a chassis the driver already had is one step:
 *   "Picked up and placed on chassis". The chassis was picked up earlier, so
 *   the box is the only thing picked up here.
 * - "Container and chassis picked up/dropped off" is only for a box and its
 *   chassis moving together.
 */
export function driverTimelineTitle(
  eventType: EventType,
  entry?: TimelineSource,
  subject: TimelineSubject = 'container',
): string {
  if (!isDriverTimelineEvent(eventType)) return eventType
  const payload = entry?.payload
  const hasBox = entry?.containerId !== null && entry?.containerId !== undefined
  const bareChassis = payload?.kind === 'BARE_CHASSIS' || (Boolean(entry?.chassisNumber) && entry?.containerId === null)

  if (eventType === 'PICKUP_CONFIRMED') {
    if (bareChassis && !hasBox) return 'Chassis picked up'
    if (payload?.attachedToBareChassis === true) {
      return subject === 'chassis' ? 'Container picked up and placed on chassis' : 'Picked up and placed on chassis'
    }
    return entry?.chassisNumber ? 'Container and chassis picked up' : 'Picked up'
  }
  if (eventType === 'DROPOFF_CONFIRMED') {
    if (bareChassis && !hasBox) return 'Chassis dropped off'
    // The drop-off names the chassis only when it stayed under the box; a
    // driver who kept the chassis took it off, and that detach has its own row.
    const stayed = Boolean(entry?.chassisNumber) && payload?.retainChassis !== false
    return stayed ? 'Container and chassis dropped off' : 'Dropped off'
  }
  if (eventType === 'CHASSIS_ATTACH') return subject === 'chassis' ? 'Container placed on chassis' : 'Placed on chassis'
  return subject === 'chassis' ? 'Container removed from chassis' : 'Removed from chassis'
}

const OTHER_TITLES: Partial<Record<EventType, string>> = {
  PICKUP_STARTED: 'Pickup started',
  DROPOFF_STARTED: 'Drop-off started',
  GATE_IN: 'Gate in',
  GATE_OUT: 'Gate out',
  ARRIVED: 'Arrived',
  DEPARTED: 'Departed',
  YARD_MOVE: 'Moved',
  LOADED: 'Loaded',
  EMPTIED: 'Emptied',
  DOCUMENT_ADDED: 'Document added',
  DAMAGE_REPORTED: 'Damage reported',
  CORRECTION: 'Correction',
  STATUS_CHANGE: 'Status change',
  RELEASED: 'Returned and released',
  ACTIVATED: 'Added to the yard',
  PICKUP_CANCELLED: 'Pickup cancelled',
}

/**
 * The words for any equipment-history row. The server writes this onto every
 * row it returns, so the app and the website read the same thing.
 */
export function equipmentEventTitle(
  eventType: EventType,
  entry?: TimelineSource,
  subject: TimelineSubject = 'container',
): string {
  if (isDriverTimelineEvent(eventType)) return driverTimelineTitle(eventType, entry, subject)
  return OTHER_TITLES[eventType] ?? eventType.toLowerCase().replace(/_/g, ' ').replace(/^./, c => c.toUpperCase())
}

export function timelineNodeKind(eventType: EventType): TimelineNodeKind {
  if (eventType === 'DROPOFF_CONFIRMED') return 'dropoff'
  if (eventType === 'CHASSIS_ATTACH') return 'attach'
  if (eventType === 'CHASSIS_DETACH') return 'detach'
  return 'pickup'
}

export interface TimelineSource {
  id: string
  eventType: EventType
  occurredAt?: string | Date | null
  tripId?: string | null
  containerId?: string | null
  chassisId?: string | null
  chassisNumber?: string | null
  payload?: Record<string, unknown> | null
}

/** A hang recorded in the same breath as the pickup that did it. */
const SAME_STEP_MS = 5000

/**
 * Hanging a container on a chassis the driver already has records a pickup
 * and a "placed on chassis" together. The pickup row already says it, so the
 * second one is left out of what people read. The stored events stay as they
 * are; only the display merges them.
 */
export function withoutRedundantHangs<T extends TimelineSource>(entries: T[]): T[] {
  const merged = entries.filter(entry => entry.eventType === 'PICKUP_CONFIRMED' && entry.payload?.attachedToBareChassis === true)
  if (!merged.length) return entries
  const at = (entry: TimelineSource) => (entry.occurredAt ? new Date(entry.occurredAt).getTime() : Number.NaN)
  return entries.filter((entry) => {
    if (entry.eventType !== 'CHASSIS_ATTACH') return true
    return !merged.some(pickup =>
      pickup.containerId === entry.containerId
      && pickup.chassisId === entry.chassisId
      && (pickup.tripId ?? null) === (entry.tripId ?? null)
      && Math.abs(at(pickup) - at(entry)) <= SAME_STEP_MS)
  })
}

/**
 * Pickups, drop-offs, and the times a container was actually placed on or
 * taken off a chassis. Nothing is invented from a row that merely names the
 * chassis the box was already riding on: hooking up to a parked pair is a
 * pickup, not a mounting.
 */
export function visibleTimelineEntries<T extends TimelineSource>(entries: T[]): T[] {
  return withoutRedundantHangs(entries.filter(entry => isDriverTimelineEvent(entry.eventType)))
}

/** Driver notes only — skip system chatter that used to crowd the rail. */
export function timelineNote(notes: string | null | undefined): string | null {
  const text = notes?.trim()
  if (!text) return null
  if (/^driver cancelled/i.test(text)) return null
  if (/final release/i.test(text)) return null
  if (/chassis released so/i.test(text)) return null
  return text
}
