import { z } from 'zod'
import { loadArrival, settleArrival } from '../../../services/arrivals'
import { requireDriver } from '../../../utils/session'

const schema = z.object({
  /** `yes` records the arrival now; `no` stops Yard Link asking. */
  answer: z.enum(['yes', 'no']),
})

/** The driver answered the arrival question, from the app or the lock screen. */
export default defineEventHandler(async (event) => {
  const auth = await requireDriver(event)
  const arrivalId = getRouterParam(event, 'id')
  if (!arrivalId) {
    throw createError({ statusCode: 400, statusMessage: 'An arrival id is required.' })
  }
  const body = await readValidatedJson(event, schema)
  const db = useDb()

  const arrival = await loadArrival(db, auth.companyId, arrivalId)
  if (!arrival || arrival.driverId !== auth.driverId) {
    throw createError({ statusCode: 404, statusMessage: 'That arrival is not waiting any more.' })
  }
  await settleArrival(db, arrival, body.answer === 'yes' ? 'CONFIRMED' : 'DISMISSED')
  return { ok: true, outcome: body.answer === 'yes' ? 'CONFIRMED' : 'DISMISSED' }
})
