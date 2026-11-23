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

// Dedupes concurrent callers (the 5-minute interval tick and any number of
// on-demand refreshes an API request triggers at the same moment) onto a
// single in-flight fetch, so a burst of stale page loads can't each kick off
// their own call to the Port Authority or insert their own duplicate row.
let inFlightPoll: Promise<{ lanes: number }> | null = null

/**
 * One poll: fetch the live feed, store one snapshot row per lane, and prune
 * anything past retention. The feed has no memory of its own — this table is
 * what makes the "worsening or improving" trend and the 24-hour graph possible.
 */
export function runBridgeCrossingPoll(db: Database): Promise<{ lanes: number }> {
  if (inFlightPoll) return inFlightPoll

  inFlightPoll = (async () => {
    try {
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
    } finally {
      inFlightPoll = null
    }
  })()

  return inFlightPoll
}
