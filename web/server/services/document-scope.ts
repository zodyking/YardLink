import { and, desc, eq, gte, isNull, inArray, lte, or } from 'drizzle-orm'
import type { SQL } from 'drizzle-orm'
import type { PgColumn } from 'drizzle-orm/pg-core'
import { chassis, containerDutyCycles, containers, documents, trips } from '../database/schema'
import { LIVE_TRIP_STATUSES } from './movements'
import { containerWindow, tripWindow } from '#shared/utils/document-scope'
import type { DocumentWindow } from '#shared/utils/document-scope'

type Db = ReturnType<typeof useDb>

/**
 * The condition that selects a trip's files: those filed on the trip itself,
 * those on its container during the container's service cycle, and those on
 * its chassis while the chassis was under the trip. A trip that does not
 * exist for this company selects nothing.
 */
export async function tripDocumentCondition(db: Db, companyId: string, tripId: string): Promise<SQL | null> {
  const [trip] = await db
    .select()
    .from(trips)
    .where(and(eq(trips.id, tripId), eq(trips.companyId, companyId)))
    .limit(1)
  if (!trip) return null

  const parts: SQL[] = [eq(documents.tripId, trip.id)]

  if (trip.containerId) {
    const [cycle] = trip.dutyCycleId
      ? await db.select().from(containerDutyCycles).where(eq(containerDutyCycles.id, trip.dutyCycleId)).limit(1)
      : []
    parts.push(equipmentFiles(documents.containerId, trip.containerId, containerWindow(trip, cycle ?? null)))
  }

  if (trip.chassisId) {
    parts.push(equipmentFiles(documents.chassisId, trip.chassisId, tripWindow(trip)))
  }

  return or(...parts) ?? null
}

/** Files on one piece of equipment that were filed inside the window. */
function equipmentFiles(column: PgColumn, id: string, window: DocumentWindow): SQL {
  const conditions = [eq(column, id), gte(documents.createdAt, window.from)]
  if (window.to) conditions.push(lte(documents.createdAt, window.to))
  return and(...conditions)!
}

export interface DocumentGroup {
  tripId: string
  containerNumber: string | null
  chassisNumber: string | null
  count: number
  /** An image file to show as a thumbnail; null when the group has none yet. */
  previewDocumentId: string | null
}

/**
 * The equipment on the driver's active trip right now, with the files filed
 * against it. A finished trip drops off this list — its files stay
 * reachable from the trip itself (Trips) or the equipment's own page
 * (Inventory), not from here.
 */
export async function driverDocumentGroups(db: Db, companyId: string, driverId: string): Promise<DocumentGroup[]> {
  const rows = await db
    .select({
      trip: trips,
      containerNumber: containers.number,
      chassisNumber: chassis.number,
    })
    .from(trips)
    .leftJoin(containers, eq(containers.id, trips.containerId))
    .leftJoin(chassis, eq(chassis.id, trips.chassisId))
    .where(and(
      eq(trips.companyId, companyId),
      eq(trips.driverId, driverId),
      inArray(trips.status, [...LIVE_TRIP_STATUSES]),
    ))
    .orderBy(desc(trips.updatedAt))

  const seen = new Set<string>()
  const groups: DocumentGroup[] = []
  for (const { trip, containerNumber, chassisNumber } of rows) {
    const key = [trip.dutyCycleId ?? trip.containerId ?? trip.id, trip.chassisId ?? '-'].join('|')
    if (seen.has(key)) continue
    seen.add(key)

    const condition = await tripDocumentCondition(db, companyId, trip.id)
    if (!condition) continue
    const files = await db
      .select({ id: documents.id, mimeType: documents.mimeType })
      .from(documents)
      .where(and(eq(documents.companyId, companyId), isNull(documents.deletedAt), condition))
      .orderBy(desc(documents.createdAt))

    groups.push({
      tripId: trip.id,
      containerNumber,
      chassisNumber,
      count: files.length,
      previewDocumentId: files.find(f => f.mimeType?.startsWith('image/'))?.id ?? null,
    })
  }
  return groups
}
