import { and, desc, eq, gte, inArray, isNull, lte, notInArray, or } from 'drizzle-orm'
import type { SQL } from 'drizzle-orm'
import type { PgColumn } from 'drizzle-orm/pg-core'
import { chassis, containerDutyCycles, containers, documents, trips } from '../database/schema'
import { containerWindow, tripWindow } from '#shared/utils/document-scope'
import type { DocumentWindow } from '#shared/utils/document-scope'

type Db = ReturnType<typeof useDb>

/** Days a finished trip stays on the driver's Documents list. */
const RECENT_DAYS = 7

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
  /** The equipment has been dropped off. */
  droppedOff: boolean
  count: number
}

/**
 * The equipment a driver has worked recently, live trips first, then the
 * drop-offs of the past week that still have files. One entry per container
 * and chassis combination in a service cycle.
 */
export async function driverDocumentGroups(db: Db, companyId: string, driverId: string): Promise<DocumentGroup[]> {
  const since = new Date(Date.now() - RECENT_DAYS * 24 * 60 * 60 * 1000)
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
      notInArray(trips.status, ['DRAFT', 'CANCELLED']),
      or(
        inArray(trips.status, ['PICKUP_IN_PROGRESS', 'IN_TRANSIT', 'DROPOFF_IN_PROGRESS']),
        gte(trips.updatedAt, since),
      ),
    ))
    .orderBy(desc(trips.updatedAt))
    .limit(60)

  const seen = new Set<string>()
  const groups: DocumentGroup[] = []
  for (const { trip, containerNumber, chassisNumber } of rows) {
    const key = [trip.dutyCycleId ?? trip.containerId ?? trip.id, trip.chassisId ?? '-'].join('|')
    if (seen.has(key)) continue
    seen.add(key)

    const condition = await tripDocumentCondition(db, companyId, trip.id)
    if (!condition) continue
    const files = await db
      .select({ id: documents.id })
      .from(documents)
      .where(and(eq(documents.companyId, companyId), isNull(documents.deletedAt), condition))
    const live = ['PICKUP_IN_PROGRESS', 'IN_TRANSIT', 'DROPOFF_IN_PROGRESS'].includes(trip.status)
    if (!live && files.length === 0) continue

    groups.push({
      tripId: trip.id,
      containerNumber,
      chassisNumber,
      droppedOff: !live,
      count: files.length,
    })
  }
  return groups
}
