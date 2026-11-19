import { z } from 'zod'
import { clearAllSwapTags } from '../../services/movements'
import { requireDriver } from '../../utils/session'

const schema = z.object({
  companyWide: z.boolean().optional(),
})

/**
 * Clear every swap pairing on the driver's own trips in one pass. "Swap"
 * tends to be the fastest way to grab a container already parked at a
 * customer, tapped far more often than there are actual same-visit
 * hookups, so history can end up with nearly everything carrying the tag.
 * This is the bulk undo for that, rather than clearing one trip at a time.
 */
export default defineEventHandler(async (event) => {
  const auth = await requireDriver(event)
  const body = await readValidatedJson(event, schema)
  const db = useDb()
  return clearAllSwapTags(db, auth, body)
})
