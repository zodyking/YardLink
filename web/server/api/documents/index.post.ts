import { z } from 'zod'
import { DOCUMENT_CATEGORIES } from '#shared/utils/domain'
import { chassis, containers, documents, locations, trips } from '../../database/schema'
import { and, eq } from 'drizzle-orm'
import { assertUploadAllowed, buildStorageKey, useObjectStorage } from '../../services/storage'
import { requireAuth } from '../../utils/session'

const schema = z.object({
  /** `data:image/jpeg;base64,…` — the same shape the camera scan route takes. */
  dataUrl: z.string().min(32).max(36_000_000),
  fileName: z.string().trim().min(1).max(180),
  category: z.enum(DOCUMENT_CATEGORIES).default('PHOTO'),
  tripId: z.string().uuid().optional(),
  containerId: z.string().uuid().optional(),
  chassisId: z.string().uuid().optional(),
  locationId: z.string().uuid().optional(),
})

const DATA_URL_RE = /^data:([\w.+-]+\/[\w.+-]+);base64,([A-Za-z0-9+/=\s]+)$/

/**
 * Save a photo or document on the server so the driver's phone, the web app
 * and dispatch all see the same file. A file filed on a trip is also filed on
 * that trip's container and chassis.
 */
export default defineEventHandler(async (event) => {
  const auth = await requireAuth(event)
  const body = await readValidatedJson(event, schema)
  const db = useDb()

  const match = DATA_URL_RE.exec(body.dataUrl)
  if (!match) throw createError({ statusCode: 422, statusMessage: 'The file could not be read.' })
  const mimeType = match[1]!.toLowerCase()
  const bytes = Buffer.from(match[2]!, 'base64')
  assertUploadAllowed(mimeType, bytes.byteLength)

  let { containerId, chassisId } = body
  if (body.tripId) {
    const [trip] = await db
      .select({ containerId: trips.containerId, chassisId: trips.chassisId })
      .from(trips)
      .where(and(eq(trips.id, body.tripId), eq(trips.companyId, auth.companyId)))
      .limit(1)
    if (!trip) throw createError({ statusCode: 404, statusMessage: 'Trip not found.' })
    containerId ??= trip.containerId ?? undefined
    chassisId ??= trip.chassisId ?? undefined
  }
  // Never file against another company's records.
  const owned = async (table: typeof containers | typeof chassis | typeof locations, id?: string) => {
    if (!id) return
    const [row] = await db.select({ id: table.id }).from(table).where(and(eq(table.id, id), eq(table.companyId, auth.companyId))).limit(1)
    if (!row) throw createError({ statusCode: 404, statusMessage: 'Record not found.' })
  }
  await owned(containers, containerId)
  await owned(chassis, chassisId)
  await owned(locations, body.locationId)

  const stored = await useObjectStorage().put(
    buildStorageKey(auth.companyId, body.category, body.fileName),
    bytes,
    mimeType,
  )

  const [doc] = await db
    .insert(documents)
    .values({
      companyId: auth.companyId,
      category: body.category,
      fileName: body.fileName,
      mimeType,
      sizeBytes: stored.size,
      storageKey: stored.key,
      checksum: stored.checksum,
      tripId: body.tripId ?? null,
      containerId: containerId ?? null,
      chassisId: chassisId ?? null,
      locationId: body.locationId ?? null,
      ocrStatus: 'NOT_IMPLEMENTED',
      uploadedByUserId: auth.userId,
    })
    .returning({
      id: documents.id,
      category: documents.category,
      fileName: documents.fileName,
      mimeType: documents.mimeType,
      sizeBytes: documents.sizeBytes,
      tripId: documents.tripId,
      containerId: documents.containerId,
      createdAt: documents.createdAt,
    })

  return { document: doc }
})
