import { BRIDGE_CROSSING_DIRECTIONS, BRIDGE_CROSSING_POLL_INTERVAL_MS } from '#shared/utils/bridge-crossings'
import { runBridgeCrossingPoll } from '../../../services/bridge-crossing-poll'
import { bridgeCrossingLaneHistory, summarizeBridgeCrossingHistory } from '../../../services/bridge-crossings'
import { loadCompanySettings } from '../../../utils/settings'
import { requireAuth } from '../../../utils/session'

/**
 * One lane's last 24 hours, for the "tap a bridge" detail graph. Same
 * on-demand freshness check as the list endpoint: a stale or missing reading
 * for this lane triggers a refresh before answering.
 */
export default defineEventHandler(async (event) => {
  await requireAuth(event)
  const db = useDb()
  const settings = await loadCompanySettings(db)
  if (!settings.bridgeCrossingTimesEnabled) {
    throw createError({ statusCode: 404, statusMessage: 'Not found.' })
  }

  const facilityId = Number(getRouterParam(event, 'facilityId'))
  const direction = getRouterParam(event, 'direction')
  if (!Number.isFinite(facilityId) || !(BRIDGE_CROSSING_DIRECTIONS as readonly string[]).includes(direction ?? '')) {
    throw createError({ statusCode: 400, statusMessage: 'Unknown bridge crossing.' })
  }
  const dir = direction as typeof BRIDGE_CROSSING_DIRECTIONS[number]

  let history = await bridgeCrossingLaneHistory(db, facilityId, dir)
  const newest = history[history.length - 1]?.recordedAt.getTime() ?? 0
  if (Date.now() - newest > BRIDGE_CROSSING_POLL_INTERVAL_MS) {
    try {
      await runBridgeCrossingPoll(db)
      history = await bridgeCrossingLaneHistory(db, facilityId, dir)
    } catch (error) {
      console.warn('[bridge-crossings] on-demand refresh failed', error instanceof Error ? error.message : error)
    }
  }

  const lane = summarizeBridgeCrossingHistory(facilityId, dir, history)
  if (!lane) {
    throw createError({ statusCode: 404, statusMessage: 'No readings yet for that crossing.' })
  }

  return { lane, history, lastUpdated: history[history.length - 1]?.recordedAt.toISOString() ?? null }
})
