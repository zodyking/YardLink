import { and, desc, eq, isNull } from 'drizzle-orm'
import { z } from 'zod'
import { documents } from '../../database/schema'
import { requireAuth } from '../../utils/session'

const querySchema = z.object({
  tripId: z.string().uuid().optional(),
  containerId: z.string().uuid().optional(),
  chassisId: z.string().uuid().optional(),
})

/** Files saved against a trip, container or chassis, newest first. */
export default defineEventHandler(async (event) => {
  const auth = await requireAuth(event)
  const query = readValidatedQuery(event, querySchema)
  if (!query.tripId && !query.containerId && !query.chassisId) {
    throw createError({ statusCode: 400, statusMessage: 'Say which trip, container or chassis.' })
  }

  const filters = [eq(documents.companyId, auth.companyId), isNull(documents.deletedAt)]
  if (query.tripId) filters.push(eq(documents.tripId, query.tripId))
  if (query.containerId) filters.push(eq(documents.containerId, query.containerId))
  if (query.chassisId) filters.push(eq(documents.chassisId, query.chassisId))

  const items = await useDb()
    .select({
      id: documents.id,
      category: documents.category,
      fileName: documents.fileName,
      mimeType: documents.mimeType,
      sizeBytes: documents.sizeBytes,
      tripId: documents.tripId,
      containerId: documents.containerId,
      createdAt: documents.createdAt,
    })
    .from(documents)
    .where(and(...filters))
    .orderBy(desc(documents.createdAt))
    .limit(200)

  return { items }
})
