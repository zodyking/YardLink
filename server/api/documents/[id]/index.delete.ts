import { and, eq, isNull } from 'drizzle-orm'
import { documents } from '../../../database/schema'
import { assertTenant, requireAuth } from '../../../utils/session'

/** Remove a file. Drivers can remove their own uploads; dispatchers any. */
export default defineEventHandler(async (event) => {
  const auth = await requireAuth(event)
  const id = getRouterParam(event, 'id')
  if (!id) throw createError({ statusCode: 400, statusMessage: 'Document id is required.' })

  const db = useDb()
  const [doc] = await db.select().from(documents).where(and(eq(documents.id, id), isNull(documents.deletedAt))).limit(1)
  assertTenant(auth, doc, 'Document')
  if (auth.role !== 'ADMIN' && doc!.uploadedByUserId !== auth.userId) {
    throw createError({ statusCode: 403, statusMessage: 'Only the person who added this file can remove it.' })
  }

  // Soft delete: the record of what was shared stays in message history.
  await db.update(documents).set({ deletedAt: new Date() }).where(eq(documents.id, id))
  return { ok: true }
})
