import { testPush } from '../../services/push'
import { requireAuth } from '../../utils/session'

/** The person's own phones get a test notice, so a phone can check itself. */
export default defineEventHandler(async (event) => {
  const auth = await requireAuth(event)
  const result = await testPush(useDb(), auth.userId)
  return {
    ok: true,
    message: `Sent to ${result.sent} of ${result.devices} ${result.devices === 1 ? 'phone' : 'phones'}. It should arrive in a few seconds.`,
  }
})
