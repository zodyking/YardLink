import { z } from 'zod'
import { forgetDevice } from '../../services/push'
import { requireAuth } from '../../utils/session'

const schema = z.object({
  token: z.string().trim().max(200),
})

/** Sign-out and disconnect stop the notices to that phone. */
export default defineEventHandler(async (event) => {
  await requireAuth(event)
  const body = await readValidatedJson(event, schema)
  if (body.token) await forgetDevice(useDb(), body.token.toLowerCase())
  return { ok: true }
})
