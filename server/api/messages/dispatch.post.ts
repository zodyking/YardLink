import { z } from 'zod'
import { MESSAGE_BODY_MAX, dispatchThreadFor, postMessage } from '../../services/messages'
import { requireDriver } from '../../utils/session'

const schema = z.object({
  id: z.string().uuid().optional(),
  body: z.string().max(MESSAGE_BODY_MAX).default(''),
  kind: z.enum(['TEXT', 'TRIP_UPDATE']).default('TEXT'),
  tripId: z.string().uuid().optional(),
  documentIds: z.array(z.string().uuid()).max(20).optional(),
})

/**
 * Driver → dispatch in one call. The pickup and drop-off update a driver used
 * to text to the dispatch number is sent here, with its photos attached.
 */
export default defineEventHandler(async (event) => {
  const auth = await requireDriver(event)
  const body = await readValidatedJson(event, schema)
  const db = useDb()
  const thread = await dispatchThreadFor(db, auth.companyId, auth.userId)
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
  return { threadId: thread.id, message: { ...message, mine: true } }
})
