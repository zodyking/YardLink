import { and, asc, desc, eq, gte } from 'drizzle-orm'
import { bridgeCrossingSnapshots } from '../database/schema'
import type { Database } from '../utils/db'
import {
  BRIDGE_CROSSING_TREND_WINDOW_MS,
  bridgeCrossingLaneKey,
  classifyBridgeCrossingTrend,
  type BridgeCrossingDirection,
  type BridgeCrossingTrend,
} from '#shared/utils/bridge-crossings'

export interface BridgeCrossingLaneView {
  facilityId: number
  crossingName: string
  direction: BridgeCrossingDirection
  travelTimeMinutes: number
  typicalTimeMinutes: number | null
  isClosed: boolean
  trend: BridgeCrossingTrend
  sourceTimestamp: string | null
  recordedAt: Date
}

/**
 * The most recent reading timestamp across every lane, or null if the table
 * is empty. Used both to decide whether an on-demand refresh is worth
 * kicking off and to show the page's own "last updated" stamp.
 */
export async function latestBridgeCrossingRecordedAt(db: Database): Promise<Date | null> {
  const [row] = await db
    .select({ recordedAt: bridgeCrossingSnapshots.recordedAt })
    .from(bridgeCrossingSnapshots)
    .orderBy(desc(bridgeCrossingSnapshots.recordedAt))
    .limit(1)
  return row?.recordedAt ?? null
}

/** Every lane's latest reading, with a trend against a reading from ~30 minutes earlier. */
export async function listBridgeCrossingLanes(db: Database): Promise<BridgeCrossingLaneView[]> {
  const newest = await latestBridgeCrossingRecordedAt(db)
  if (!newest) return []

  // Windowed off the newest reading actually on hand, not wall-clock time, so
  // a lane keeps showing its last known reading (with a trend) if the feed or
  // the poll has gone stale, instead of quietly going empty 30+ minutes later.
  const since = new Date(newest.getTime() - BRIDGE_CROSSING_TREND_WINDOW_MS - 5 * 60 * 1000)
  const rows = await db
    .select()
    .from(bridgeCrossingSnapshots)
    .where(gte(bridgeCrossingSnapshots.recordedAt, since))
    .orderBy(asc(bridgeCrossingSnapshots.recordedAt))

  type Row = (typeof rows)[number]
  const latestByLane = new Map<string, Row>()
  const earliestByLane = new Map<string, Row>()
  for (const row of rows) {
    const key = bridgeCrossingLaneKey(row.facilityId, row.direction)
    if (!earliestByLane.has(key)) earliestByLane.set(key, row)
    latestByLane.set(key, row)
  }

  return [...latestByLane.values()]
    .map((latest) => {
      const key = bridgeCrossingLaneKey(latest.facilityId, latest.direction)
      const previous = earliestByLane.get(key)?.travelTimeMinutes ?? null
      return {
        facilityId: latest.facilityId,
        crossingName: latest.crossingName,
        direction: latest.direction,
        travelTimeMinutes: latest.travelTimeMinutes,
        typicalTimeMinutes: latest.typicalTimeMinutes,
        isClosed: latest.isClosed,
        trend: classifyBridgeCrossingTrend(latest.travelTimeMinutes, previous),
        sourceTimestamp: latest.sourceTimestamp,
        recordedAt: latest.recordedAt,
      }
    })
    .sort((a, b) => a.facilityId - b.facilityId || a.direction.localeCompare(b.direction))
}

export interface BridgeCrossingHistoryPoint {
  crossingName: string
  travelTimeMinutes: number
  typicalTimeMinutes: number | null
  isClosed: boolean
  recordedAt: Date
}

/** Up to the last 24 hours of readings for one lane, oldest first, for the detail graph. */
export async function bridgeCrossingLaneHistory(
  db: Database,
  facilityId: number,
  direction: BridgeCrossingDirection,
  hours = 24,
): Promise<BridgeCrossingHistoryPoint[]> {
  const since = new Date(Date.now() - hours * 60 * 60 * 1000)
  return db
    .select({
      crossingName: bridgeCrossingSnapshots.crossingName,
      travelTimeMinutes: bridgeCrossingSnapshots.travelTimeMinutes,
      typicalTimeMinutes: bridgeCrossingSnapshots.typicalTimeMinutes,
      isClosed: bridgeCrossingSnapshots.isClosed,
      recordedAt: bridgeCrossingSnapshots.recordedAt,
    })
    .from(bridgeCrossingSnapshots)
    .where(and(
      eq(bridgeCrossingSnapshots.facilityId, facilityId),
      eq(bridgeCrossingSnapshots.direction, direction),
      gte(bridgeCrossingSnapshots.recordedAt, since),
    ))
    .orderBy(asc(bridgeCrossingSnapshots.recordedAt))
}

/** The current reading plus a trend, derived from an already-fetched history (last ~24h). */
export function summarizeBridgeCrossingHistory(
  facilityId: number,
  direction: BridgeCrossingDirection,
  history: BridgeCrossingHistoryPoint[],
): Omit<BridgeCrossingLaneView, 'sourceTimestamp'> | null {
  const latest = history[history.length - 1]
  if (!latest) return null

  const previousCutoff = latest.recordedAt.getTime() - BRIDGE_CROSSING_TREND_WINDOW_MS
  let previous: number | null = null
  for (const point of history) {
    if (point.recordedAt.getTime() <= previousCutoff) previous = point.travelTimeMinutes
    else break
  }

  return {
    facilityId,
    crossingName: latest.crossingName,
    direction,
    travelTimeMinutes: latest.travelTimeMinutes,
    typicalTimeMinutes: latest.typicalTimeMinutes,
    isClosed: latest.isClosed,
    trend: classifyBridgeCrossingTrend(latest.travelTimeMinutes, previous),
    recordedAt: latest.recordedAt,
  }
}
