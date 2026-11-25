import { listTimeCardWatchSites } from '../../services/time-cards'
import { requireDriver } from '../../utils/session'

/** The company's pinned sites, for the phone to watch while filling in the time card. */
export default defineEventHandler(async (event) => {
  const auth = await requireDriver(event)
  return { sites: await listTimeCardWatchSites(useDb(), auth) }
})
