import { and, eq } from 'drizzle-orm'
import { z } from 'zod'
import { companyMemberships } from '../../../database/schema'
import { directThreadFor, dispatchThreadFor } from '../../../services/messages'
import { requireAuth } from '../../../utils/session'

const schema = z.object({
  /** Open (or find) the conversation with this person. */
  userId: z.string().uuid().optional(),
  /** Driver: open my line to dispatch. Dispatcher with userId: that driver's dispatch line. */
  dispatch: z.boolean().optional(),
})

export default defineEventHandler(async (event) => {
  const auth = await requireAuth(event)
  const body = await readValidatedJson(event, schema)
  const db = useDb()

  if (body.dispatch && auth.role === 'DRIVER') {
    return { threadId: (await dispatchThreadFor(db, auth.companyId, auth.userId)).id }
  }
  if (!body.userId) {
    throw createError({ statusCode: 400, statusMessage: 'Pick someone to message.' })
  }

  const [member] = await db
    .select({ role: companyMemberships.role })
    .from(companyMemberships)
    .where(and(eq(companyMemberships.userId, body.userId), eq(companyMemberships.companyId, auth.companyId)))
    .limit(1)
  if (!member) throw createError({ statusCode: 404, statusMessage: 'Person not found.' })

  // A dispatcher writing to a driver always uses that driver's dispatch line,
  // so the rest of the desk can see what was said.
  if (auth.role === 'ADMIN' && member.role === 'DRIVER') {
    return { threadId: (await dispatchThreadFor(db, auth.companyId, body.userId)).id }
  }
  // A driver writing to a dispatcher lands in the same shared line.
  if (auth.role === 'DRIVER' && member.role === 'ADMIN') {
    return { threadId: (await dispatchThreadFor(db, auth.companyId, auth.userId)).id }
  }
  return { threadId: (await directThreadFor(db, auth.companyId, auth.userId, body.userId)).id }
})
