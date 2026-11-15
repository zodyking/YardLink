import { unreadTotal } from '../../services/messages'
import { requireAuth } from '../../utils/session'

/** Small enough to poll for the Messages badge. */
export default defineEventHandler(async (event) => {
  const auth = await requireAuth(event)
  return { unread: await unreadTotal(useDb(), auth) }
})
