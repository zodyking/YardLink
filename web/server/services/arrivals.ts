import { and, eq, isNull, lte, sql } from 'drizzle-orm'
import { drivers, locations, tripArrivals, trips } from '../database/schema'
import type { Database, DbExecutor } from '../utils/db'
import type { AuthContext } from '../utils/session'
import { recordEvent } from './events'
import { LIVE_TRIP_STATUSES } from './movements'
import { pushArrivalQuestion } from './push'
import { parseCoord, withinRadius } from '#shared/utils/geo'

/**
 * Arrivals that answer themselves.
 *
 * A phone crossing into a site's circle tells the server at once. The driver
 * is asked whether they have arrived; if nobody answers within the wait, the
 * arrival is recorded anyway — stamped at the moment of the crossing, never at
 * the moment the sweep happened to run. The server holds the timer, so it
 * still fires when the phone is asleep or the app was killed.
 */
export const ARRIVAL_WAIT_MINUTES = 10

export type ArrivalFix = {
  latitude: number
  longitude: number
  accuracyMeters?: number | null
  at?: Date | null
}

export type ArrivalOutcome = 'CONFIRMED' | 'AUTO' | 'DISMISSED'

type OpenArrival = typeof tripArrivals.$inferSelect

/** The live trip this driver is on, with where it is headed. */
async function liveTrip(db: DbExecutor, auth: AuthContext & { driverId: string }) {
  const [row] = await db
    .select({
      id: trips.id,
      destinationLocationId: trips.destinationLocationId,
      originLocationId: trips.originLocationId,
      status: trips.status,
    })
    .from(trips)
    .where(and(
      eq(trips.companyId, auth.companyId),
      eq(trips.driverId, auth.driverId),
      sql`${trips.status} in ${LIVE_TRIP_STATUSES}`,
    ))
    .orderBy(sql`${trips.createdAt} desc`)
    .limit(1)
  return row ?? null
}

/** Which site this fix is inside, preferring the one the trip is headed to. */
async function siteForFix(
  db: DbExecutor,
  companyId: string,
  fix: ArrivalFix,
  preferLocationId: string | null,
) {
  const rows = await db
    .select({
      id: locations.id,
      name: locations.name,
      latitude: locations.latitude,
      longitude: locations.longitude,
      arrivalRadiusM: locations.arrivalRadiusM,
    })
    .from(locations)
    .where(and(eq(locations.companyId, companyId), isNull(locations.deletedAt)))

  const inside = rows.filter((row) => {
    const latitude = parseCoord(row.latitude)
    const longitude = parseCoord(row.longitude)
    if (latitude == null || longitude == null) return false
    return withinRadius(fix, { latitude, longitude }, row.arrivalRadiusM)
  })
  if (!inside.length) return null
  return inside.find(row => row.id === preferLocationId) ?? inside[0]!
}

/**
 * The phone crossed into a circle. Returns the arrival that is now waiting on
 * the driver, or null when there is nothing to ask about.
 */
export async function openArrival(
  db: Database,
  auth: AuthContext & { driverId: string },
  fix: ArrivalFix,
): Promise<{ arrival: OpenArrival, locationName: string } | null> {
  const trip = await liveTrip(db, auth)
  if (!trip) return null

  const site = await siteForFix(db, auth.companyId, fix, trip.destinationLocationId)
  if (!site) return null
  // Leaving the yard you started from is not an arrival.
  if (site.id === trip.originLocationId && site.id !== trip.destinationLocationId) return null

  const enteredAt = fix.at ?? new Date()
  const autoAt = new Date(enteredAt.getTime() + ARRIVAL_WAIT_MINUTES * 60_000)

  const [row] = await db
    .insert(tripArrivals)
    .values({
      companyId: auth.companyId,
      tripId: trip.id,
      driverId: auth.driverId,
      locationId: site.id,
      enteredAt,
      autoAt,
      latitude: String(fix.latitude),
      longitude: String(fix.longitude),
      accuracyMeters: fix.accuracyMeters ?? null,
    })
    .onConflictDoNothing({ target: [tripArrivals.tripId, tripArrivals.locationId] })
    .returning()

  // Already asked about this trip and site: leave the first question standing.
  if (!row) return null

  await pushArrivalQuestion(db, {
    driverId: auth.driverId,
    arrivalId: row.id,
    locationName: site.name,
    waitMinutes: ARRIVAL_WAIT_MINUTES,
  }).catch(error => console.warn('[arrivals] could not ask the driver', error))

  return { arrival: row, locationName: site.name }
}

/** Write the ARRIVED event, stamped at the crossing. */
async function recordArrivedEvent(
  db: Database,
  arrival: OpenArrival,
  outcome: ArrivalOutcome,
): Promise<string> {
  const eventId = crypto.randomUUID()
  const [driver] = await db
    .select({ userId: drivers.userId })
    .from(drivers)
    .where(eq(drivers.id, arrival.driverId))
    .limit(1)
  const [trip] = await db
    .select({ containerId: trips.containerId, chassisId: trips.chassisId })
    .from(trips)
    .where(eq(trips.id, arrival.tripId))
    .limit(1)

  const latitude = parseCoord(arrival.latitude)
  const longitude = parseCoord(arrival.longitude)

  await db.transaction(async (tx) => {
    await recordEvent(tx, {
      id: eventId,
      companyId: arrival.companyId,
      containerId: trip?.containerId ?? null,
      eventType: 'ARRIVED',
      occurredAt: arrival.enteredAt,
      actorUserId: driver?.userId ?? null,
      actorDriverId: arrival.driverId,
      tripId: arrival.tripId,
      locationId: arrival.locationId,
      chassisId: trip?.chassisId ?? null,
      gps: latitude != null && longitude != null
        ? { latitude, longitude, accuracyMeters: arrival.accuracyMeters ?? undefined }
        : null,
      payload: { source: outcome === 'AUTO' ? 'geofence-auto' : 'geofence-confirmed' },
    })
  })
  return eventId
}

/** The driver answered, or the wait ran out. */
export async function settleArrival(
  db: Database,
  arrival: OpenArrival,
  outcome: ArrivalOutcome,
): Promise<void> {
  if (arrival.settledAt) return
  const eventId = outcome === 'DISMISSED' ? null : await recordArrivedEvent(db, arrival, outcome)
  await db
    .update(tripArrivals)
    .set({ settledAt: new Date(), outcome, eventId })
    .where(and(eq(tripArrivals.id, arrival.id), isNull(tripArrivals.settledAt)))
}

export async function loadArrival(
  db: Database,
  companyId: string,
  arrivalId: string,
): Promise<OpenArrival | null> {
  const [row] = await db
    .select()
    .from(tripArrivals)
    .where(and(eq(tripArrivals.id, arrivalId), eq(tripArrivals.companyId, companyId)))
    .limit(1)
  return row ?? null
}

/** Arrivals nobody answered. Called on a timer and after any arrival call. */
export async function settleDueArrivals(db: Database, now: Date = new Date()): Promise<number> {
  const due = await db
    .select()
    .from(tripArrivals)
    .where(and(isNull(tripArrivals.settledAt), lte(tripArrivals.autoAt, now)))
    .limit(50)

  let settled = 0
  for (const arrival of due) {
    try {
      await settleArrival(db, arrival, 'AUTO')
      settled += 1
    }
    catch (error) {
      console.warn('[arrivals] could not record an automatic arrival', error)
    }
  }
  return settled
}

/** The question the phone shows when it opens on a waiting arrival. */
export async function openArrivalFor(
  db: Database,
  auth: AuthContext & { driverId: string },
): Promise<{ id: string, locationName: string, enteredAt: string, autoAt: string } | null> {
  const [row] = await db
    .select({
      id: tripArrivals.id,
      enteredAt: tripArrivals.enteredAt,
      autoAt: tripArrivals.autoAt,
      locationName: locations.name,
    })
    .from(tripArrivals)
    .innerJoin(locations, eq(locations.id, tripArrivals.locationId))
    .where(and(
      eq(tripArrivals.companyId, auth.companyId),
      eq(tripArrivals.driverId, auth.driverId),
      isNull(tripArrivals.settledAt),
    ))
    .orderBy(sql`${tripArrivals.enteredAt} desc`)
    .limit(1)
  if (!row) return null
  return {
    id: row.id,
    locationName: row.locationName,
    enteredAt: row.enteredAt.toISOString(),
    autoAt: row.autoAt.toISOString(),
  }
}

