import { z } from 'zod'
import { saveShipcsxResults } from '../../services/shipcsx'
import { requireAuth } from '../../utils/session'

const body = z.object({
  terminal: z.string().trim().min(1).max(80),
  containerIds: z.array(z.string().uuid()).max(50),
  /** The results page as read, one entry per ShipCSX results tab. */
  tabs: z.array(z.object({
    tab: z.string().trim().max(20).nullish(),
    text: z.string().max(200_000),
  })).min(1).max(6),
  listedOnly: z.boolean().optional(),
})

/** Save the statuses a ShipCSX results page showed, after a person's search in the app. */
export default defineEventHandler(async (event) => {
  const auth = await requireAuth(event)
  const input = await readValidatedJson(event, body)
  return saveShipcsxResults(useDb(), auth, input)
})
