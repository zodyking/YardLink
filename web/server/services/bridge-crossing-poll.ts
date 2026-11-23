import { lt } from 'drizzle-orm'
import { bridgeCrossingSnapshots } from '../database/schema'
import type { Database } from '../utils/db'
import {
  BRIDGE_CROSSING_FEED_URL,
  BRIDGE_CROSSING_RETENTION_MS,
  parseBridgeCrossingFeed,
} from '#shared/utils/bridge-crossings'

async function fetchBridgeCrossingFeed(): Promise<unknown> {
  const response = await fetch(BRIDGE_CROSSING_FEED_URL, {
    headers: { 'Accept': 'application/json' },
    signal: AbortSignal.timeout(8_000),
  })
  if (!response.ok) {
    throw new Error(`Port Authority feed responded ${response.status}`)
  }
  return response.json()
}

/**
 * One poll: fetch the live feed, store one snapshot row per lane, and prune
 * anything past retention. The feed has no memory of its own — this table is
 * what makes the "worsening or improving" trend and the 24-hour graph possible.
 */
export async function runBridgeCrossingPoll(db: Database): Promise<{ lanes: number }> {
  const raw = await fetchBridgeCrossingFeed()
  const lanes = parseBridgeCrossingFeed(raw)
  if (!lanes.length) return { lanes: 0 }

  await db.insert(bridgeCrossingSnapshots).values(lanes.map(lane => ({
    facilityId: lane.facilityId,
    crossingName: lane.crossingName,
    direction: lane.direction,
    travelTimeMinutes: lane.travelTimeMinutes,
    typicalTimeMinutes: lane.typicalTimeMinutes,
    isClosed: lane.isClosed,
    sourceTimestamp: lane.sourceTimestamp,
  })))

  await db
    .delete(bridgeCrossingSnapshots)
    .where(lt(bridgeCrossingSnapshots.recordedAt, new Date(Date.now() - BRIDGE_CROSSING_RETENTION_MS)))

  return { lanes: lanes.length }
}
