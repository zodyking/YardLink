import { requireAdmin } from '../../../utils/session'
import { testPush } from '../../../services/push'

/** Sends a test notice to the dispatcher's own phones. */
export default defineEventHandler(async (event) => {
  const auth = await requireAdmin(event)
  const result = await testPush(useDb(), auth.userId)
  return {
    ok: true,
    message: `Sent to ${result.sent} of ${result.devices} ${result.devices === 1 ? 'phone' : 'phones'}.`,
  }
})
