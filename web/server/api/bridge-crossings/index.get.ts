import { BRIDGE_CROSSING_POLL_INTERVAL_MS } from '#shared/utils/bridge-crossings'
import { runBridgeCrossingPoll } from '../../services/bridge-crossing-poll'
import { latestBridgeCrossingRecordedAt, listBridgeCrossingLanes } from '../../services/bridge-crossings'
import { loadCompanySettings } from '../../utils/settings'
import { requireAuth } from '../../utils/session'

/**
 * Every Hudson River crossing's current reading (upper level only for the
 * GWB, its one facility with a level split), each with a trend against a
 * reading from ~30 minutes earlier. 404s when the company hasn't turned
 * this on — hiding the Tools row client-side is never enough on its own.
 *
 * Opening this page is itself a freshness check: if the newest reading on
 * hand is more than one poll interval old (or there isn't one yet — e.g. the
 * setting was just switched on), this refreshes from the Port Authority
 * before answering, so a driver never has to wait out the background poll's
 * own 5-minute cadence to see a reading.
 */
export default defineEventHandler(async (event) => {
  await requireAuth(event)
  const db = useDb()
  const settings = await loadCompanySettings(db)
  if (!settings.bridgeCrossingTimesEnabled) {
    throw createError({ statusCode: 404, statusMessage: 'Not found.' })
  }

  const newest = await latestBridgeCrossingRecordedAt(db)
  const isStale = !newest || Date.now() - newest.getTime() > BRIDGE_CROSSING_POLL_INTERVAL_MS
  if (isStale) {
    try {
      await runBridgeCrossingPoll(db)
    } catch (error) {
      // Feed's unreachable right now - fall through and serve whatever's
      // already stored rather than erroring the whole page out.
      console.warn('[bridge-crossings] on-demand refresh failed', error instanceof Error ? error.message : error)
    }
  }

  const lanes = await listBridgeCrossingLanes(db)
  const lastUpdated = lanes.length
    ? new Date(Math.max(...lanes.map(lane => lane.recordedAt.getTime()))).toISOString()
    : null
  return { lanes, lastUpdated }
})
