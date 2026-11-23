import { z } from 'zod'
import { recordManualTrip } from '../../services/movements'
import { syncTodayTimeCardQuietly } from '../../services/time-cards'
import { requireDriver } from '../../utils/session'
import { CONTAINER_TYPES, EQUIPMENT_TYPES, TRIP_KINDS } from '#shared/utils/domain'

const schema = z.object({
  kind: z.enum(TRIP_KINDS),
  containerNumber: z.string().trim().max(20).optional(),
  containerType: z.enum(CONTAINER_TYPES).optional(),
  equipmentType: z.enum(EQUIPMENT_TYPES).optional(),
  chassisNumber: z.string().trim().max(20).optional(),
  isLoaded: z.boolean().default(false),
  sealNumber: z.string().trim().max(40).nullish(),
  originLocationId: z.string().uuid('Select where the trip started.'),
  destinationLocationId: z.string().uuid('Select where the trip ended.'),
  customer: z.string().trim().max(120).nullish(),
  pickedUpAt: z.coerce.date(),
  droppedOffAt: z.coerce.date(),
  notes: z.string().trim().max(2000).nullish(),
  resolvesGap: z.object({
    priorTripId: z.string().uuid(),
    nextTripId: z.string().uuid(),
  }).nullish(),
})

/**
 * Record a trip the driver ran without the app — forgot to log it live, or
 * it happened before they started using it — with the real equipment and
 * stops entered up front. Writes straight to a finished trip, the same way
 * a live pickup-then-drop-off would leave things, so the driver's time card
 * (stopsFromTrips) and the equipment's own record both pick it up exactly
 * as if it had run through the app normally.
 */
export default defineEventHandler(async (event) => {
  const auth = await requireDriver(event)
  const body = await readValidatedJson(event, schema)
  const db = useDb()

  const result = await recordManualTrip(db, auth, body)

  await syncTodayTimeCardQuietly(db, auth, body.pickedUpAt)
  if (body.droppedOffAt.getTime() !== body.pickedUpAt.getTime()) {
    await syncTodayTimeCardQuietly(db, auth, body.droppedOffAt)
  }

  return result
})
