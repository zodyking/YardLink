/**
 * Which files belong to a trip. Files follow the container's service cycle:
 * a photo taken on the pickup is still there after the drop-off, and a later
 * cycle of the same container starts with a clean slate. A chassis' files
 * stay with it only for as long as it was under this trip.
 */
export interface DocumentWindow {
  from: Date
  to: Date | null
}

interface WindowTrip {
  createdAt: Date
  pickedUpAt: Date | null
  droppedOffAt: Date | null
  completedAt: Date | null
  status: string
}

interface WindowCycle {
  startedAt: Date
  completedAt: Date | null
}

const ENDED = new Set(['DROPPED_OFF', 'COMPLETED', 'CANCELLED', 'EXCEPTION'])

/** The container's service cycle if there is one, otherwise the trip alone. */
export function containerWindow(trip: WindowTrip, cycle: WindowCycle | null): DocumentWindow {
  if (cycle) return { from: cycle.startedAt, to: cycle.completedAt }
  return tripWindow(trip)
}

/** From pickup (or creation) until the drop-off, still open while underway. */
export function tripWindow(trip: WindowTrip): DocumentWindow {
  const from = trip.pickedUpAt ?? trip.createdAt
  const end = trip.droppedOffAt ?? trip.completedAt
  return { from, to: ENDED.has(trip.status) ? end : null }
}

export function withinWindow(at: Date, window: DocumentWindow): boolean {
  if (at < window.from) return false
  return window.to === null || at <= window.to
}
