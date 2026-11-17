import { requireAdmin } from '../../../utils/session'
import { savePushConfig, summarizePush } from '../../../utils/push-settings'

/**
 * Turns push notifications off. Phones keep working; they simply find new
 * messages and work the next time the app is opened.
 */
export default defineEventHandler(async (event) => {
  const auth = await requireAdmin(event)
  await savePushConfig(useDb(), auth.companyId, null)
  return { ok: true, push: summarizePush(null) }
})
