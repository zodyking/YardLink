import { z } from 'zod'
import { listMessages, loadThreadFor, markThreadRead } from '../../../services/messages'
import { requireAuth } from '../../../utils/session'

const querySchema = z.object({
  /** Only messages after this moment — used when polling an open conversation. */
  after: z.string().datetime().optional(),
})

export default defineEventHandler(async (event) => {
  const auth = await requireAuth(event)
  const id = getRouterParam(event, 'id')
  if (!id) throw createError({ statusCode: 400, statusMessage: 'Conversation is required.' })
  const query = readValidatedQuery(event, querySchema)
  const db = useDb()

  const thread = await loadThreadFor(db, auth, id)
  const items = await listMessages(db, auth, thread.id, query.after ? new Date(query.after) : null)
  await markThreadRead(db, thread.id, auth.userId)
  return { threadId: thread.id, kind: thread.kind, messages: items }
})
