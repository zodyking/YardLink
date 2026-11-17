import type { EventType } from './domain'

/** Events a driver should see on trip and equipment history. */
export const DRIVER_TIMELINE_EVENT_TYPES = [
  'PICKUP_CONFIRMED',
  'DROPOFF_CONFIRMED',
  'CHASSIS_ATTACH',
  'CHASSIS_DETACH',
] as const

export type DriverTimelineEventType = (typeof DRIVER_TIMELINE_EVENT_TYPES)[number]

export const DRIVER_TIMELINE_TITLES: Record<DriverTimelineEventType, string> = {
  PICKUP_CONFIRMED: 'Picked up',
  DROPOFF_CONFIRMED: 'Dropped off',
  CHASSIS_ATTACH: 'Container placed on chassis',
  CHASSIS_DETACH: 'Container removed from chassis',
}

export type TimelineNodeKind = 'pickup' | 'dropoff' | 'attach' | 'detach'

export function isDriverTimelineEvent(eventType: EventType): eventType is DriverTimelineEventType {
  return (DRIVER_TIMELINE_EVENT_TYPES as readonly string[]).includes(eventType)
}

/**
 * What happened, in the driver's words. A pickup or drop-off that names a
 * chassis moved both pieces of equipment at once, and says so.
 */
export function driverTimelineTitle(eventType: EventType, entry?: TimelineSource): string {
  if (!isDriverTimelineEvent(eventType)) return eventType
  const bareChassis = entry?.payload?.kind === 'BARE_CHASSIS'
  if (eventType === 'PICKUP_CONFIRMED') {
    if (bareChassis) return 'Chassis picked up'
    return entry?.chassisNumber ? 'Container and chassis picked up' : 'Picked up'
  }
  if (eventType === 'DROPOFF_CONFIRMED') {
    if (bareChassis) return 'Chassis dropped off'
    // The box staying on its chassis is one move; a driver who keeps the
    // chassis took it off, and that detach gets a row of its own.
    const keptChassis = entry?.payload?.retainChassis === true
    return entry?.chassisNumber && keptChassis ? 'Container and chassis dropped off' : 'Dropped off'
  }
  return DRIVER_TIMELINE_TITLES[eventType]
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
  chassisNumber?: string | null
  payload?: Record<string, unknown> | null
}

/**
 * Pickups, drop-offs, and the times a container was actually placed on or
 * taken off a chassis. Nothing is invented from a row that merely names the
 * chassis the box was already riding on: hooking up to a parked pair is a
 * pickup, not a mounting.
 */
export function visibleTimelineEntries<T extends TimelineSource>(entries: T[]): T[] {
  return entries.filter(entry => isDriverTimelineEvent(entry.eventType))
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
