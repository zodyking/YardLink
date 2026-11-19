import { z } from 'zod'
import { correctTripDetails } from '../../services/movements'
import { requireDriver } from '../../utils/session'

const schema = z.object({
  notes: z.string().trim().max(2000).nullish(),
  originLocationId: z.string().uuid().nullish(),
  destinationLocationId: z.string().uuid().nullish(),
})

/**
 * Correct a trip's own record: its notes, or which locations it ran
 * between. Works on a trip of any status except a cancelled one — old
 * finished trips, and ones reconstructed to fill a missing-trip gap, are
 * editable here, not just live ones.
 */
export default defineEventHandler(async (event) => {
  const auth = await requireDriver(event)
  const tripId = getRouterParam(event, 'id')

  if (!tripId) {
    throw createError({ statusCode: 400, statusMessage: 'Trip id is required.' })
  }

  const body = await readValidatedJson(event, schema)
  const db = useDb()
  return correctTripDetails(db, auth, { ...body, tripId })
})
