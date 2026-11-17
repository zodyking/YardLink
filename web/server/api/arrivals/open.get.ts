import { openArrivalFor, settleDueArrivals } from '../../services/arrivals'
import { requireDriver } from '../../utils/session'

/** The arrival question still waiting on this driver, if there is one. */
export default defineEventHandler(async (event) => {
  const auth = await requireDriver(event)
  const db = useDb()
  await settleDueArrivals(db)
  return { arrival: await openArrivalFor(db, auth) }
})
