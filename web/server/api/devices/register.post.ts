import { z } from 'zod'
import { rememberDevice } from '../../services/push'
import { requireAuth } from '../../utils/session'

const schema = z.object({
  token: z.string().trim().regex(/^[0-9a-fA-F]{32,200}$/, 'That is not an Apple device token.'),
  /** A build signed with a development profile talks to Apple's sandbox. */
  sandbox: z.coerce.boolean().default(false),
  appVersion: z.string().trim().max(40).optional(),
})

/** The phone hands over its push token after sign-in, and on every launch. */
export default defineEventHandler(async (event) => {
  const auth = await requireAuth(event)
  const body = await readValidatedJson(event, schema)
  await rememberDevice(useDb(), {
    userId: auth.userId,
    companyId: auth.companyId,
    token: body.token.toLowerCase(),
    sandbox: body.sandbox,
    appVersion: body.appVersion ?? null,
  })
  return { ok: true }
})
