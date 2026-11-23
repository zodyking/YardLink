import { aliasedTable, and, asc, desc, eq, gte, inArray, isNotNull, isNull, lte, ne, or } from 'drizzle-orm'
import {
  chassis,
  containers,
  containerEvents,
  driverTimeCards,
  drivers,
  locations,
  trips,
  trucks,
  users,
} from '../database/schema'
import type { Database, DbExecutor } from '../utils/db'
import type { AuthContext } from '../utils/session'
import { companyTimezone } from './tasks'
import { correctTripDetails, LIVE_TRIP_STATUSES, type CorrectTripDetailsInput } from './movements'
import { addIsoDays, calendarDateInZone } from '#shared/utils/sms-task'
import { parseCoord } from '#shared/utils/geo'
import {
  annotatePingsWithSites,
  applyHeaderOverrides,
  blankTimeCardHeader,
  cdlLabel,
  headerOverrideFields,
  isTimeCardWorkDate,
  markStopCorrections,
  mergeIncomingPing,
  mergeTimeCardStops,
  minutesFromClock,
  routeCustomerFromTrips,
  sanitizeTimeCardStop,
  shiftTotals,
  stopsFromPings,
  stopsFromTrips,
  sumOnDutyHours,
  TIME_CARD_HEADER_FIELDS,
  TIME_CARD_STOP_MAX,
  trailerFromTrips,
  zonedDayRange,
  type TimeCardHeader,
  type TimeCardHeaderField,
  type TimeCardPing,
  type TimeCardSite,
  type TimeCardStatus,
  type TimeCardStop,
  type TimeCardTripInput,
} from '#shared/utils/time-card'
import type { TimeCardDirectoryEntry } from '#shared/utils/time-card-layout'

export type TimeCardView = {
  id: string
  workDate: string
  status: TimeCardStatus
  header: TimeCardHeader
  stops: TimeCardStop[]
  pingCount: number
  live: boolean
}

export type TimeCardListItem = {
  workDate: string
  status: TimeCardStatus
  stopCount: number
  totalOnDutyHours: string
}

function asStops(value: unknown): TimeCardStop[] {
  if (!Array.isArray(value)) return []
  return value
    .map(item => sanitizeTimeCardStop(item as Partial<TimeCardStop>))
    .filter((item): item is TimeCardStop => Boolean(item))
}

function asPings(value: unknown): TimeCardPing[] {
  if (!Array.isArray(value)) return []
  const pings: TimeCardPing[] = []
  for (const item of value) {
    if (!item || typeof item !== 'object') continue
    const row = item as TimeCardPing
    const latitude = Number(row.latitude)
    const longitude = Number(row.longitude)
    if (!Number.isFinite(latitude) || !Number.isFinite(longitude)) continue
    if (!row.at) continue
    pings.push({
      at: String(row.at),
      latitude,
      longitude,
      accuracyMeters: row.accuracyMeters == null ? null : Number(row.accuracyMeters),
      locationId: row.locationId ? String(row.locationId) : null,
      locationName: row.locationName ? String(row.locationName) : null,
    })
  }
  return pings
}

function asHeader(value: unknown, workDate: string): TimeCardHeader {
  const blank = blankTimeCardHeader(workDate)
  if (!value || typeof value !== 'object') return blank
  const row = value as Record<string, unknown>
  const next = { ...blank }
  for (const key of Object.keys(blank) as (keyof TimeCardHeader)[]) {
    if (typeof row[key] === 'string') next[key] = row[key] as string
  }
  next.date = blank.date
  return next
}

function asOverrides(value: unknown): TimeCardHeaderField[] {
  if (!Array.isArray(value)) return []
  return value.filter((item): item is TimeCardHeaderField =>
    TIME_CARD_HEADER_FIELDS.includes(item as TimeCardHeaderField),
  )
}

function requireWorkDate(workDate: string): string {
  const trimmed = workDate.trim()
  if (!isTimeCardWorkDate(trimmed)) {
    throw createError({ statusCode: 400, statusMessage: 'Use a work date like 2026-10-28.' })
  }
  return trimmed
}

function requireDriverAuth(auth: AuthContext): AuthContext & { driverId: string } {
  if (!auth.driverId) {
    throw createError({ statusCode: 403, statusMessage: 'Driver access required.' })
  }
  return auth as AuthContext & { driverId: string }
}

async function loadSites(db: DbExecutor, companyId: string): Promise<TimeCardSite[]> {
  const rows = await db
    .select({
      id: locations.id,
      name: locations.name,
      city: locations.city,
      state: locations.state,
      latitude: locations.latitude,
      longitude: locations.longitude,
    })
    .from(locations)
    .where(and(
      eq(locations.companyId, companyId),
      isNull(locations.deletedAt),
    ))

  return rows.map(row => ({
    id: row.id,
    name: row.name,
    city: row.city,
    state: row.state,
    latitude: parseCoord(row.latitude),
    longitude: parseCoord(row.longitude),
  }))
}

/** This company's own active yards/terminals, for the time card PDF's page-2 directory. */
export async function loadTimeCardDirectory(db: DbExecutor, companyId: string): Promise<TimeCardDirectoryEntry[]> {
  const rows = await db
    .select({
      name: locations.name,
      addressLine1: locations.addressLine1,
      addressLine2: locations.addressLine2,
      city: locations.city,
      state: locations.state,
      postalCode: locations.postalCode,
      mainPhone: locations.mainPhone,
    })
    .from(locations)
    .where(and(
      eq(locations.companyId, companyId),
      eq(locations.status, 'ACTIVE'),
      isNull(locations.deletedAt),
    ))
    .orderBy(asc(locations.name))

  return rows.map((row): TimeCardDirectoryEntry => ({
    name: row.name,
    address: [
      row.addressLine1,
      row.addressLine2,
      [row.city, row.state].filter(Boolean).join(', '),
      row.postalCode,
    ].filter(part => part && part.trim()).join(', '),
    phone: row.mainPhone ?? '',
  }))
}

async function loadDayTrips(
  db: DbExecutor,
  auth: AuthContext & { driverId: string },
  workDate: string,
  timeZone: string,
): Promise<TimeCardTripInput[]> {
  const { start, end } = zonedDayRange(workDate, timeZone)
  const origin = aliasedTable(locations, 'time_card_origin')
  const destination = aliasedTable(locations, 'time_card_destination')
  const rows = await db
    .select({
      id: trips.id,
      kind: trips.kind,
      isLoaded: trips.isLoaded,
      customer: trips.customer,
      createdAt: trips.createdAt,
      pickedUpAt: trips.pickedUpAt,
      droppedOffAt: trips.droppedOffAt,
      originLocationId: trips.originLocationId,
      destinationLocationId: trips.destinationLocationId,
      originName: origin.name,
      originCity: origin.city,
      originState: origin.state,
      destinationName: destination.name,
      destinationCity: destination.city,
      destinationState: destination.state,
      containerNumber: containers.number,
      chassisNumber: chassis.number,
    })
    .from(trips)
    .leftJoin(containers, eq(containers.id, trips.containerId))
    .leftJoin(chassis, eq(chassis.id, trips.chassisId))
    .leftJoin(origin, eq(origin.id, trips.originLocationId))
    .leftJoin(destination, eq(destination.id, trips.destinationLocationId))
    .where(and(
      eq(trips.companyId, auth.companyId),
      eq(trips.driverId, auth.driverId),
      ne(trips.status, 'CANCELLED'),
      or(
        and(gte(trips.createdAt, new Date(start.getTime() - 36 * 3600 * 1000)), lte(trips.createdAt, new Date(end.getTime() + 12 * 3600 * 1000))),
        and(isNotNull(trips.pickedUpAt), gte(trips.pickedUpAt, start), lte(trips.pickedUpAt, end)),
        and(isNotNull(trips.droppedOffAt), gte(trips.droppedOffAt, start), lte(trips.droppedOffAt, end)),
      ),
    ))

  return rows
    .filter((row) => {
      const stamps = [row.createdAt, row.pickedUpAt, row.droppedOffAt].filter(Boolean) as Date[]
      return stamps.some(stamp => calendarDateInZone(stamp, timeZone) === workDate)
    })
    .map(row => ({
      id: row.id,
      kind: row.kind,
      isLoaded: row.isLoaded,
      customer: row.customer,
      createdAt: row.createdAt,
      pickedUpAt: row.pickedUpAt,
      droppedOffAt: row.droppedOffAt,
      originLocationId: row.originLocationId,
      destinationLocationId: row.destinationLocationId,
      originName: row.originName,
      originCity: row.originCity,
      originState: row.originState,
      destinationName: row.destinationName,
      destinationCity: row.destinationCity,
      destinationState: row.destinationState,
      containerNumber: row.containerNumber,
      chassisNumber: row.chassisNumber,
    }))
}

async function loadEventPings(
  db: DbExecutor,
  auth: AuthContext & { driverId: string },
  workDate: string,
  timeZone: string,
  sites: readonly TimeCardSite[],
): Promise<TimeCardPing[]> {
  const { start, end } = zonedDayRange(workDate, timeZone)
  const rows = await db
    .select({
      at: containerEvents.occurredAt,
      latitude: containerEvents.gpsLatitude,
      longitude: containerEvents.gpsLongitude,
      accuracyMeters: containerEvents.gpsAccuracyMeters,
      locationId: containerEvents.locationId,
    })
    .from(containerEvents)
    .where(and(
      eq(containerEvents.companyId, auth.companyId),
      eq(containerEvents.actorDriverId, auth.driverId),
      isNotNull(containerEvents.gpsLatitude),
      isNotNull(containerEvents.gpsLongitude),
      gte(containerEvents.occurredAt, start),
      lte(containerEvents.occurredAt, end),
    ))
    .orderBy(containerEvents.occurredAt)

  const siteById = new Map(sites.map(site => [site.id, site]))
  const pings: TimeCardPing[] = []
  for (const row of rows) {
    const latitude = parseCoord(row.latitude)
    const longitude = parseCoord(row.longitude)
    if (latitude == null || longitude == null) continue
    const site = row.locationId ? siteById.get(row.locationId) : null
    pings.push({
      at: row.at.toISOString(),
      latitude,
      longitude,
      accuracyMeters: row.accuracyMeters ?? null,
      locationId: site?.id ?? null,
      locationName: site?.name ?? null,
    })
  }
  return annotatePingsWithSites(pings, sites)
}

async function loadDriverHeaderBits(
  db: DbExecutor,
  auth: AuthContext & { driverId: string },
  dayTrips: readonly TimeCardTripInput[],
): Promise<Pick<TimeCardHeader, 'driverName' | 'truckUnit' | 'trailerNumber' | 'cdl' | 'employeeId' | 'routeCustomer'>> {
  const [driver] = await db
    .select({
      driverCode: drivers.driverCode,
      cdlNumber: drivers.cdlNumber,
      cdlState: drivers.cdlState,
      preferredTruckId: drivers.preferredTruckId,
      firstName: users.firstName,
      lastName: users.lastName,
    })
    .from(drivers)
    .innerJoin(users, eq(users.id, drivers.userId))
    .where(eq(drivers.id, auth.driverId))
    .limit(1)

  let truckVin = ''
  if (driver?.preferredTruckId) {
    const [truck] = await db
      .select({ vin: trucks.vin })
      .from(trucks)
      .where(eq(trucks.id, driver.preferredTruckId))
      .limit(1)
    truckVin = truck?.vin?.trim() || ''
  }

  return {
    driverName: [driver?.firstName, driver?.lastName].filter(Boolean).join(' ').trim() || auth.fullName,
    truckUnit: truckVin,
    trailerNumber: trailerFromTrips(dayTrips),
    cdl: cdlLabel(driver?.cdlNumber, driver?.cdlState),
    employeeId: driver?.driverCode?.trim() || '',
    routeCustomer: routeCustomerFromTrips(dayTrips),
  }
}

/** The seven cards before this one, for the short-haul "preceding 7 days" box. */
async function precedingOnDutyHours(
  db: DbExecutor,
  auth: AuthContext & { driverId: string },
  workDate: string,
): Promise<string> {
  const dates: string[] = []
  for (let back = 1; back <= 7; back += 1) {
    const day = addIsoDays(workDate, -back)
    if (day) dates.push(day)
  }
  if (!dates.length) return ''
  const rows = await db
    .select({ header: driverTimeCards.header, stops: driverTimeCards.stops, workDate: driverTimeCards.workDate })
    .from(driverTimeCards)
    .where(and(
      eq(driverTimeCards.companyId, auth.companyId),
      eq(driverTimeCards.driverId, auth.driverId),
      inArray(driverTimeCards.workDate, dates),
    ))
  const totals = rows.map((row) => {
    const saved = asHeader(row.header, row.workDate).totalOnDutyHours
    return saved || shiftTotals(asStops(row.stops)).totalOnDutyHours
  })
  return sumOnDutyHours(totals)
}

async function ensureRow(
  db: DbExecutor,
  auth: AuthContext & { driverId: string },
  workDate: string,
) {
  const [existing] = await db
    .select()
    .from(driverTimeCards)
    .where(and(
      eq(driverTimeCards.companyId, auth.companyId),
      eq(driverTimeCards.driverId, auth.driverId),
      eq(driverTimeCards.workDate, workDate),
    ))
    .limit(1)

  if (existing) return existing

  await db.insert(driverTimeCards).values({
    companyId: auth.companyId,
    driverId: auth.driverId,
    workDate,
    status: 'OPEN',
    stops: [],
    pings: [],
    header: blankTimeCardHeader(workDate),
    headerOverrides: [],
  }).onConflictDoNothing({ target: [driverTimeCards.driverId, driverTimeCards.workDate] })

  const [row] = await db
    .select()
    .from(driverTimeCards)
    .where(and(
      eq(driverTimeCards.companyId, auth.companyId),
      eq(driverTimeCards.driverId, auth.driverId),
      eq(driverTimeCards.workDate, workDate),
    ))
    .limit(1)

  if (!row) {
    throw createError({ statusCode: 500, statusMessage: 'Could not open today\'s time card.' })
  }
  return row
}

function toView(
  row: typeof driverTimeCards.$inferSelect,
  live: boolean,
): TimeCardView {
  const workDate = row.workDate
  const stops = asStops(row.stops)
  const header = asHeader(row.header, workDate)
  return {
    id: row.id,
    workDate,
    status: row.status === 'COMPLETED' ? 'COMPLETED' : 'OPEN',
    header,
    stops,
    pingCount: asPings(row.pings).length,
    live,
  }
}

export async function listDriverTimeCards(
  db: Database,
  auth: AuthContext,
  limit = 60,
): Promise<TimeCardListItem[]> {
  const driverAuth = requireDriverAuth(auth)
  const rows = await db
    .select({
      workDate: driverTimeCards.workDate,
      status: driverTimeCards.status,
      stops: driverTimeCards.stops,
      header: driverTimeCards.header,
    })
    .from(driverTimeCards)
    .where(and(
      eq(driverTimeCards.companyId, driverAuth.companyId),
      eq(driverTimeCards.driverId, driverAuth.driverId),
    ))
    .orderBy(desc(driverTimeCards.workDate))
    .limit(limit)

  return rows.map((row) => {
    const stops = asStops(row.stops)
    const header = asHeader(row.header, row.workDate)
    return {
      workDate: row.workDate,
      status: row.status === 'COMPLETED' ? 'COMPLETED' : 'OPEN',
      stopCount: stops.length,
      totalOnDutyHours: header.totalOnDutyHours,
    }
  })
}

export async function syncDriverTimeCard(
  db: DbExecutor,
  auth: AuthContext,
  workDateInput: string,
): Promise<TimeCardView> {
  const driverAuth = requireDriverAuth(auth)
  const workDate = requireWorkDate(workDateInput)
  const timeZone = await companyTimezone(db, driverAuth.companyId)
  const row = await ensureRow(db, driverAuth, workDate)
  const sites = await loadSites(db, driverAuth.companyId)
  const dayTrips = await loadDayTrips(db, driverAuth, workDate, timeZone)
  const storedPings = annotatePingsWithSites(asPings(row.pings), sites)
  const eventPings = await loadEventPings(db, driverAuth, workDate, timeZone, sites)

  let pings = storedPings
  for (const ping of eventPings) pings = mergeIncomingPing(pings, ping)
  pings = annotatePingsWithSites(pings, sites)

  const auto = mergeTimeCardStops(
    [...stopsFromTrips(dayTrips, timeZone), ...stopsFromPings(pings, timeZone)],
    [],
  )
  const stops = mergeTimeCardStops(auto, asStops(row.stops))
  const bits = await loadDriverHeaderBits(db, driverAuth, dayTrips)
  const savedHeader = asHeader(row.header, workDate)
  const autoHeader: TimeCardHeader = {
    ...blankTimeCardHeader(workDate),
    ...bits,
    startOdometer: savedHeader.startOdometer,
    endOdometer: savedHeader.endOdometer,
    dispatcher: savedHeader.dispatcher,
  }
  const header = {
    ...applyHeaderOverrides(autoHeader, savedHeader, asOverrides(row.headerOverrides)),
    date: blankTimeCardHeader(workDate).date,
    ...shiftTotals(stops),
    preceding7DayHours: await precedingOnDutyHours(db, driverAuth, workDate),
    signedName: savedHeader.signedName,
    signedDate: savedHeader.signedDate,
  }
  const status: TimeCardStatus = 'OPEN'
  const now = new Date()

  const [updated] = await db
    .update(driverTimeCards)
    .set({
      status,
      stops,
      pings,
      header,
      updatedAt: now,
    })
    .where(eq(driverTimeCards.id, row.id))
    .returning()

  const live = await driverIsLive(db, driverAuth.companyId, driverAuth.driverId)
  return toView(updated ?? { ...row, status, stops, pings, header, updatedAt: now }, live)
}

async function driverIsLive(db: DbExecutor, companyId: string, driverId: string): Promise<boolean> {
  const [row] = await db
    .select({ id: trips.id })
    .from(trips)
    .where(and(
      eq(trips.companyId, companyId),
      eq(trips.driverId, driverId),
      inArray(trips.status, [...LIVE_TRIP_STATUSES]),
    ))
    .limit(1)
  return Boolean(row)
}

export async function getDriverTimeCard(
  db: Database,
  auth: AuthContext,
  workDate: string,
): Promise<TimeCardView> {
  return syncDriverTimeCard(db, auth, workDate)
}

export async function recordTimeCardPing(
  db: Database,
  auth: AuthContext,
  input: { latitude: number, longitude: number, accuracyMeters?: number | null, at?: string | Date | null },
): Promise<{ accepted: boolean, live: boolean, workDate: string, card: TimeCardView }> {
  const driverAuth = requireDriverAuth(auth)
  if (!Number.isFinite(input.latitude) || !Number.isFinite(input.longitude)) {
    throw createError({ statusCode: 422, statusMessage: 'A GPS fix is required.' })
  }
  const timeZone = await companyTimezone(db, driverAuth.companyId)
  const at = input.at ? new Date(input.at) : new Date()
  const workDate = calendarDateInZone(Number.isNaN(at.getTime()) ? new Date() : at, timeZone)
  const row = await ensureRow(db, driverAuth, workDate)
  const sites = await loadSites(db, driverAuth.companyId)
  const ping: TimeCardPing = {
    at: (Number.isNaN(at.getTime()) ? new Date() : at).toISOString(),
    latitude: input.latitude,
    longitude: input.longitude,
    accuracyMeters: input.accuracyMeters ?? null,
  }
  const pings = mergeIncomingPing(
    annotatePingsWithSites(asPings(row.pings), sites),
    annotatePingsWithSites([ping], sites)[0]!,
  )
  await db
    .update(driverTimeCards)
    .set({ pings, updatedAt: new Date() })
    .where(eq(driverTimeCards.id, row.id))

  const card = await syncDriverTimeCard(db, driverAuth, workDate)
  return { accepted: true, live: card.live, workDate, card }
}

/** Minutes a submitted clock time moved from the auto baseline, or null if unreadable or unchanged. */
function clockDeltaMinutes(submitted: string, base: string): number | null {
  const next = minutesFromClock(submitted)
  const prior = minutesFromClock(base)
  if (next == null || prior == null || next === prior) return null
  return next - prior
}

/**
 * A driver correcting a TRIP-sourced stop on the time card is really
 * correcting the trip — the stop is just that trip's pickup or drop-off
 * rendered as a clock reading and a place name. Carries the same change
 * over to the real trip, so the trip and every place that reads it
 * (history, equipment records, the dispatcher console) lines up with what
 * the time card now says, rather than the two quietly disagreeing forever.
 *
 * Timing is carried over as a whole-minute delta rather than by
 * reconstructing an instant from the clock string and the card's time
 * zone, so it is exact regardless of DST or odd zone offsets. A place is
 * only ever carried over from `locationId` — a real pick off the location
 * list — never from the free-text label next to it: the label alone
 * cannot be trusted to name one real place, and guessing wrong would
 * quietly move a container's recorded stop to the wrong yard. A
 * correction the auto baseline cannot read (an unparsed clock, a stop with
 * no matching trip, a place typed rather than picked) is simply left alone.
 */
async function applyTripStopCorrections(
  db: Database,
  auth: AuthContext & { driverId: string },
  submitted: readonly TimeCardStop[],
  auto: readonly TimeCardStop[],
  dayTrips: readonly TimeCardTripInput[],
): Promise<Set<string>> {
  const autoByKey = new Map(auto.map(stop => [stop.key, stop]))
  const tripsById = new Map(dayTrips.map(trip => [trip.id, trip]))
  const corrected = new Set<string>()

  for (const stop of submitted) {
    if (stop.source !== 'TRIP' || !stop.tripId) continue
    const base = autoByKey.get(stop.key)
    const trip = tripsById.get(stop.tripId)
    if (!base || !trip) continue
    const isPickup = stop.key.endsWith(':PICKUP')
    const isDropoff = stop.key.endsWith(':DROPOFF')
    if (!isPickup && !isDropoff) continue

    const correction: CorrectTripDetailsInput = { tripId: stop.tripId }

    if (isPickup) {
      const delta = clockDeltaMinutes(stop.timeOut, base.timeOut)
      const pickedUpAt = trip.pickedUpAt ? new Date(trip.pickedUpAt) : null
      if (delta != null && pickedUpAt) correction.pickedUpAt = new Date(pickedUpAt.getTime() + delta * 60_000)
      if (stop.locationId && stop.locationId !== base.locationId) correction.originLocationId = stop.locationId
    }
    else {
      const delta = clockDeltaMinutes(stop.timeOut, base.timeOut) ?? clockDeltaMinutes(stop.timeIn, base.timeIn)
      const droppedOffAt = trip.droppedOffAt ? new Date(trip.droppedOffAt) : null
      if (delta != null && droppedOffAt) correction.droppedOffAt = new Date(droppedOffAt.getTime() + delta * 60_000)
      if (stop.locationId && stop.locationId !== base.locationId) correction.destinationLocationId = stop.locationId
    }

    if (!correction.pickedUpAt && !correction.droppedOffAt && !correction.originLocationId && !correction.destinationLocationId) continue

    try {
      await correctTripDetails(db, auth, correction)
      corrected.add(stop.tripId)
    }
    catch (error) {
      // A rejected correction (e.g. it would put drop-off before pickup,
      // or names a location from a different company) leaves the trip
      // exactly as it was; the card still shows the driver's edit, just
      // marked as a correction rather than silently rewriting the trip
      // underneath them.
      console.warn('[time-card] could not apply a trip stop correction', error)
    }
  }

  return corrected
}

export async function patchDriverTimeCard(
  db: Database,
  auth: AuthContext,
  workDateInput: string,
  body: {
    header?: Partial<TimeCardHeader>
    stops?: Array<Partial<TimeCardStop>>
  },
): Promise<TimeCardView> {
  const driverAuth = requireDriverAuth(auth)
  const workDate = requireWorkDate(workDateInput)
  const current = await syncDriverTimeCard(db, driverAuth, workDate)
  const timeZone = await companyTimezone(db, driverAuth.companyId)
  const row = await ensureRow(db, driverAuth, workDate)
  let dayTrips = await loadDayTrips(db, driverAuth, workDate, timeZone)
  const sites = await loadSites(db, driverAuth.companyId)
  const pings = annotatePingsWithSites(asPings(row.pings), sites)
  let auto = mergeTimeCardStops(
    [...stopsFromTrips(dayTrips, timeZone), ...stopsFromPings(pings, timeZone)],
    [],
  )

  const submittedStops = Array.isArray(body.stops)
    ? body.stops
        .map(item => sanitizeTimeCardStop(item))
        .filter((item): item is TimeCardStop => Boolean(item))
        .slice(0, TIME_CARD_STOP_MAX)
    : asStops(row.stops)

  // A driver's edit to a trip-sourced stop — its clock time or which place
  // it names — is a correction to the trip itself, not just to this card —
  // push it back so trip history and the time card never disagree about
  // what actually happened or where. Re-derive the auto baseline
  // afterward, since the trips it is built from just changed.
  const correctedTrips = await applyTripStopCorrections(db, driverAuth, submittedStops, auto, dayTrips)
  if (correctedTrips.size) {
    dayTrips = await loadDayTrips(db, driverAuth, workDate, timeZone)
    auto = mergeTimeCardStops(
      [...stopsFromTrips(dayTrips, timeZone), ...stopsFromPings(pings, timeZone)],
      [],
    )
  }

  const stops = mergeTimeCardStops(auto, markStopCorrections(submittedStops, auto))

  const savedHeader = asHeader(row.header, workDate)
  const submittedHeader = body.header ?? {}
  const bits = await loadDriverHeaderBits(db, driverAuth, dayTrips)
  const autoHeader: TimeCardHeader = {
    ...blankTimeCardHeader(workDate),
    ...bits,
    startOdometer: savedHeader.startOdometer,
    endOdometer: savedHeader.endOdometer,
    dispatcher: savedHeader.dispatcher,
  }
  const mergedSubmitted: Partial<TimeCardHeader> = {}
  for (const field of TIME_CARD_HEADER_FIELDS) {
    if (typeof submittedHeader[field] === 'string') {
      mergedSubmitted[field] = submittedHeader[field]!.trim().slice(0, 80)
    }
  }
  const overrides = headerOverrideFields(autoHeader, { ...savedHeader, ...mergedSubmitted })
  const header = {
    ...applyHeaderOverrides(autoHeader, { ...savedHeader, ...mergedSubmitted }, overrides),
    date: blankTimeCardHeader(workDate).date,
    ...shiftTotals(stops),
    preceding7DayHours: await precedingOnDutyHours(db, driverAuth, workDate),
    signedName: savedHeader.signedName,
    signedDate: savedHeader.signedDate,
  }
  const status: TimeCardStatus = 'OPEN'

  const [updated] = await db
    .update(driverTimeCards)
    .set({
      status,
      stops,
      header,
      headerOverrides: overrides,
      updatedAt: new Date(),
    })
    .where(eq(driverTimeCards.id, row.id))
    .returning()

  return toView(updated ?? { ...row, status, stops, header, headerOverrides: overrides }, current.live)
}

export async function syncTodayTimeCardQuietly(
  db: DbExecutor,
  auth: AuthContext,
  at: Date = new Date(),
): Promise<void> {
  if (!auth.driverId) return
  try {
    const timeZone = await companyTimezone(db, auth.companyId)
    const workDate = calendarDateInZone(at, timeZone)
    await syncDriverTimeCard(db, auth, workDate)
  }
  catch (error) {
    console.warn('[time-card] could not sync after a trip change', error)
  }
}
