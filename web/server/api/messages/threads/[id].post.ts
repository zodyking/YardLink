import { z } from 'zod'
import { sendMessageEmails } from '../../../services/emails'
import { pushMessage } from '../../../services/push'
import { MESSAGE_BODY_MAX, loadThreadFor, postMessage } from '../../../services/messages'
import { requireAuth } from '../../../utils/session'

const schema = z.object({
  id: z.string().uuid().optional(),
  body: z.string().max(MESSAGE_BODY_MAX).default(''),
  kind: z.enum(['TEXT', 'TRIP_UPDATE']).default('TEXT'),
  tripId: z.string().uuid().optional(),
  documentIds: z.array(z.string().uuid()).max(20).optional(),
})

export default defineEventHandler(async (event) => {
  const auth = await requireAuth(event)
  const id = getRouterParam(event, 'id')
  if (!id) throw createError({ statusCode: 400, statusMessage: 'Conversation is required.' })
  const body = await readValidatedJson(event, schema)
  const db = useDb()

  const thread = await loadThreadFor(db, auth, id)
  const message = await postMessage(db, {
    id: body.id,
    companyId: auth.companyId,
    threadId: thread.id,
    senderUserId: auth.userId,
    senderName: auth.fullName,
    body: body.body,
    kind: body.kind,
    tripId: body.tripId ?? null,
    documentIds: body.documentIds,
  })
  await sendMessageEmails(db, {
    thread,
    messageId: message.id,
    senderUserId: auth.userId,
    senderName: auth.fullName,
    body: message.body,
  }).catch(error => console.warn('[messages] email copy failed', error))
  await pushMessage(db, {
    thread,
    senderUserId: auth.userId,
    senderName: auth.fullName,
    body: message.body,
  }).catch(error => console.warn('[messages] push failed', error))
  return { message: { ...message, mine: true } }
})
