import { z } from 'zod'
import { addContainerAtLocation } from '../../../services/equipment-moves'
import { requireAuth } from '../../../utils/session'
import { CONTAINER_TYPES, EQUIPMENT_TYPES } from '#shared/utils/domain'

const schema = z.object({
  eventId: z.string().uuid('An idempotency key is required.'),
  containerNumber: z.string().trim().min(1),
  containerType: z.enum(CONTAINER_TYPES),
  equipmentType: z.enum(EQUIPMENT_TYPES).default('DRY_40'),
  isLoaded: z.boolean(),
  sealNumber: z.string().trim().max(60).nullish(),
  chassisNumber: z.string().trim().max(40).nullish(),
})

/** Record a container at this location. */
export default defineEventHandler(async (event) => {
  const auth = await requireAuth(event)
  const locationId = getRouterParam(event, 'id')
  if (!locationId) {
    throw createError({ statusCode: 400, statusMessage: 'Location id is required.' })
  }
  const body = await readValidatedJson(event, schema)
  return addContainerAtLocation(useDb(), auth, { ...body, locationId })
})
