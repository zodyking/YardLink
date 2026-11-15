import { listThreads } from '../../services/messages'
import { requireAuth } from '../../utils/session'

/** Conversations for the signed-in person, most recent first. */
export default defineEventHandler(async (event) => {
  const auth = await requireAuth(event)
  const threads = await listThreads(useDb(), auth)
  return { threads, unread: threads.reduce((sum, thread) => sum + thread.unread, 0) }
})
