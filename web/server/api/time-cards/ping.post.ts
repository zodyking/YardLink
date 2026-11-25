import { z } from 'zod'
import { TIME_CARD_SITE_EVENTS } from '#shared/utils/time-card'
import { recordTimeCardPing } from '../../services/time-cards'
import { requireDriver } from '../../utils/session'

const schema = z.object({
  latitude: z.number().min(-90).max(90),
  longitude: z.number().min(-180).max(180),
  accuracyMeters: z.number().min(0).max(50_000).optional(),
  at: z.string().trim().max(40).optional(),
  /** Set when the phone crossed into or out of a site it was watching. */
  event: z.enum(TIME_CARD_SITE_EVENTS).optional(),
  siteId: z.string().uuid().optional(),
})

/** Where the phone is for the time card: a fix while the app is open, or a site crossing reported in the background. */
export default defineEventHandler(async (event) => {
  const auth = await requireDriver(event)
  const body = await readValidatedJson(event, schema)
  return recordTimeCardPing(useDb(), auth, body)
})
