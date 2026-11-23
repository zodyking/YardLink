import { BRIDGE_CROSSING_DIRECTIONS } from '#shared/utils/bridge-crossings'
import { bridgeCrossingLaneHistory, summarizeBridgeCrossingHistory } from '../../../services/bridge-crossings'
import { loadCompanySettings } from '../../../utils/settings'
import { requireAuth } from '../../../utils/session'

/** One lane's last 24 hours, for the "tap a bridge" detail graph. */
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

  const history = await bridgeCrossingLaneHistory(db, facilityId, direction as typeof BRIDGE_CROSSING_DIRECTIONS[number])
  const lane = summarizeBridgeCrossingHistory(facilityId, direction as typeof BRIDGE_CROSSING_DIRECTIONS[number], history)
  if (!lane) {
    throw createError({ statusCode: 404, statusMessage: 'No readings yet for that crossing.' })
  }

  return { lane, history }
})
