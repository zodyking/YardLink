import { listBridgeCrossingLanes } from '../../services/bridge-crossings'
import { loadCompanySettings } from '../../utils/settings'
import { requireAuth } from '../../utils/session'

/**
 * Every Hudson River crossing's current reading (upper level only for the
 * GWB, its one facility with a level split), each with a trend against a
 * reading from ~30 minutes earlier. 404s when the company hasn't turned
 * this on — hiding the Tools row client-side is never enough on its own.
 */
export default defineEventHandler(async (event) => {
  await requireAuth(event)
  const db = useDb()
  const settings = await loadCompanySettings(db)
  if (!settings.bridgeCrossingTimesEnabled) {
    throw createError({ statusCode: 404, statusMessage: 'Not found.' })
  }
  const lanes = await listBridgeCrossingLanes(db)
  return { lanes }
})
