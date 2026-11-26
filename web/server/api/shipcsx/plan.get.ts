import { z } from 'zod'
import { shipcsxCheckPlan } from '../../services/shipcsx'
import { requireAuth } from '../../utils/session'

const querySchema = z.object({ containerId: z.string().uuid().optional() })

/** Which containers Check CSX fills in, and the CSX location it picks. */
export default defineEventHandler(async (event) => {
  const auth = await requireAuth(event)
  const { containerId } = readValidatedQuery(event, querySchema)
  return shipcsxCheckPlan(useDb(), auth, containerId)
})
