import { z } from 'zod'
import { shipcsxCheckPlan } from '../../services/shipcsx'
import { requireAuth } from '../../utils/session'

const querySchema = z.object({ containerId: z.string().uuid().optional() })

/**
 * What Check CSX searches: one container when one is named, otherwise every
 * container that is loaded, at a customer or at a company yard.
 */
export default defineEventHandler(async (event) => {
  const auth = await requireAuth(event)
  const { containerId } = readValidatedQuery(event, querySchema)
  return shipcsxCheckPlan(useDb(), auth, containerId)
})
