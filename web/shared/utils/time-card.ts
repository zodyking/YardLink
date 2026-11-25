import { haversineMeters } from './geo'
import { addIsoDays, calendarDateInZone } from './sms-task'

export const TIME_CARD_STOP_MAX = 25
export const TIME_CARD_GPS_RADIUS_M = 400
export const TIME_CARD_PING_MIN_GAP_M = 80
export const TIME_CARD_PING_MAX = 400
export const TIME_CARD_GPS_ACCURACY_MAX_M = 800
export const TIME_CARD_DATE_RE = /^(\d{4})-(\d{2})-(\d{2})$/

export const TIME_CARD_STATUSES = ['OPEN', 'COMPLETED'] as const
export type TimeCardStatus = (typeof TIME_CARD_STATUSES)[number]

export const TIME_CARD_STOP_SOURCES = ['TRIP', 'GPS', 'MANUAL'] as const
export type TimeCardStopSource = (typeof TIME_CARD_STOP_SOURCES)[number]

export const TIME_CARD_HEADER_FIELDS = [
  'driverName',
  'truckUnit',
  'trailerNumber',
  'cdl',
  'employeeId',
  'dispatcher',
  'routeCustomer',
  'startOdometer',
  'endOdometer',
] as const
export type TimeCardHeaderField = (typeof TIME_CARD_HEADER_FIELDS)[number]

export type TimeCardStop = {
  key: string
  timeIn: string
  timeOut: string
  location: string
  activity: string
  source: TimeCardStopSource
  tripId?: string | null
  locationId?: string | null
  /** The trip's customer, mirrored on both its pickup and drop-off stop. */
  customer?: string | null
  corrected?: boolean
}

export const TIME_CARD_SITE_EVENTS = ['ENTER', 'EXIT'] as const
export type TimeCardSiteEvent = (typeof TIME_CARD_SITE_EVENTS)[number]

export type TimeCardPing = {
  /** When the phone was first seen here. */
  at: string
  /** When it was last seen here, once later fixes from the same spot are folded in. */
  until?: string | null
  latitude: number
  longitude: number
  accuracyMeters?: number | null
  locationId?: string | null
  locationName?: string | null
  /** The phone crossed into or out of this company site's circle at `at`. */
  event?: TimeCardSiteEvent | null
}

export type TimeCardHeader = {
  driverName: string
  date: string
  truckUnit: string
  trailerNumber: string
  cdl: string
  employeeId: string
  dispatcher: string
  routeCustomer: string
  startOdometer: string
  endOdometer: string
  reportForDuty: string
  releasedFromDuty: string
  totalOnDutyHours: string
  preceding7DayHours: string
  signedName: string
  signedDate: string
}

export type TimeCardTripInput = {
  id: string
  kind?: string | null
  isLoaded?: boolean | null
  containerNumber?: string | null
  chassisNumber?: string | null
  customer?: string | null
  originName?: string | null
  originCity?: string | null
  originState?: string | null
  destinationName?: string | null
  destinationCity?: string | null
  destinationState?: string | null
  originLocationId?: string | null
  destinationLocationId?: string | null
  createdAt: Date | string
  pickedUpAt?: Date | string | null
  droppedOffAt?: Date | string | null
}

export type TimeCardSite = {
  id: string
  name: string
  city?: string | null
  state?: string | null
  latitude: number | null
  longitude: number | null
}

function asDate(value: Date | string | null | undefined): Date | null {
  if (!value) return null
  const date = value instanceof Date ? value : new Date(value)
  return Number.isNaN(date.getTime()) ? null : date
}

/** 24-hour `HH:mm` in the company timezone. */
export function formatTimeCardClock(value: Date | string, timeZone: string): string {
  const date = asDate(value)
  if (!date) return ''
  const parts = new Intl.DateTimeFormat('en-GB', {
    timeZone,
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  }).formatToParts(date)
  const hour = parts.find(part => part.type === 'hour')?.value
  const minute = parts.find(part => part.type === 'minute')?.value
  if (!hour || !minute) return ''
  return `${hour}:${minute}`
}

/** Printed date on the card: `MM/DD/YYYY`. */
export function formatTimeCardDate(isoDate: string): string {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(isoDate.trim())
  if (!match) return isoDate
  return `${match[2]}/${match[3]}/${match[1]}`
}

export function minutesFromClock(clock: string): number | null {
  const match = /^(\d{1,2}):(\d{2})$/.exec(clock.trim())
  if (!match) return null
  const hours = Number(match[1])
  const minutes = Number(match[2])
  if (!Number.isFinite(hours) || !Number.isFinite(minutes)) return null
  return hours * 60 + minutes
}

/** On-duty hours as `H:MM` from first in to last out. */
export function onDutyHoursLabel(timeIn: string, timeOut: string): string {
  const start = minutesFromClock(timeIn)
  const end = minutesFromClock(timeOut)
  if (start == null || end == null) return ''
  let delta = end - start
  if (delta < 0) delta += 24 * 60
  const hours = Math.floor(delta / 60)
  const minutes = delta % 60
  return `${hours}:${String(minutes).padStart(2, '0')}`
}

/** `Queens Yard, Jamaica, NY` — city and state follow the site name. */
export function formatTimeCardLocation(
  name: string | null | undefined,
  city?: string | null,
  state?: string | null,
): string {
  const title = name?.trim() || ''
  const place = [city?.trim(), state?.trim()].filter(Boolean).join(', ')
  if (!title) return place
  if (!place) return title
  return `${title}, ${place}`
}

function equipmentLabel(trip: TimeCardTripInput): string {
  if (trip.kind === 'BARE_CHASSIS') return trip.chassisNumber?.trim() || 'chassis'
  return trip.containerNumber?.trim() || 'container'
}

function loadWord(trip: TimeCardTripInput): string {
  if (trip.kind === 'BARE_CHASSIS') return 'Chassis'
  return trip.isLoaded ? 'Loaded' : 'Empty'
}

function clockSortValue(clock: string): number {
  return minutesFromClock(clock) ?? 24 * 60
}

export function sortTimeCardStops(stops: readonly TimeCardStop[]): TimeCardStop[] {
  return [...stops].sort((a, b) => clockSortValue(a.timeIn) - clockSortValue(b.timeIn)
    || clockSortValue(a.timeOut) - clockSortValue(b.timeOut)
    || a.key.localeCompare(b.key))
}

export function stopsFromTrips(trips: readonly TimeCardTripInput[], timeZone: string): TimeCardStop[] {
  const stops: TimeCardStop[] = []
  for (const trip of trips) {
    const mark = equipmentLabel(trip)
    const load = loadWord(trip)
    const origin = formatTimeCardLocation(trip.originName, trip.originCity, trip.originState)
    const created = asDate(trip.createdAt)
    const picked = asDate(trip.pickedUpAt)
    if (origin && created) {
      stops.push({
        key: `TRIP:${trip.id}:PICKUP`,
        timeIn: formatTimeCardClock(created, timeZone),
        timeOut: picked ? formatTimeCardClock(picked, timeZone) : '',
        location: origin,
        activity: `Pickup ${mark} · ${load}`,
        source: 'TRIP',
        tripId: trip.id,
        locationId: trip.originLocationId ?? null,
        customer: trip.customer ?? null,
      })
    }
    const dropped = asDate(trip.droppedOffAt)
    const dest = formatTimeCardLocation(trip.destinationName, trip.destinationCity, trip.destinationState)
    if (dropped && dest) {
      stops.push({
        key: `TRIP:${trip.id}:DROPOFF`,
        timeIn: formatTimeCardClock(dropped, timeZone),
        timeOut: formatTimeCardClock(dropped, timeZone),
        location: dest,
        activity: `Drop-off ${mark} · ${load}`,
        source: 'TRIP',
        tripId: trip.id,
        locationId: trip.destinationLocationId ?? null,
        customer: trip.customer ?? null,
      })
    }
  }
  return sortTimeCardStops(stops).slice(0, TIME_CARD_STOP_MAX)
}

function laterIso(a: string, b: string): string {
  return a.localeCompare(b) >= 0 ? a : b
}

/**
 * Time at each site from the phone: consecutive fixes at the same site, and
 * the phone's own enter/exit crossings, become one stop. A crossing out with
 * no crossing in that day (the day began on site) is a stop with only a time out.
 */
export function stopsFromPings(pings: readonly TimeCardPing[], timeZone: string): TimeCardStop[] {
  const ordered = [...pings].sort((a, b) => a.at.localeCompare(b.at))
  const dwells: TimeCardStop[] = []
  let open: { locationId: string, locationName: string, first: string | null, last: string } | null = null

  function close() {
    if (!open) return
    dwells.push({
      key: `GPS:${open.locationId}:${open.first ?? open.last}`,
      timeIn: open.first ? formatTimeCardClock(open.first, timeZone) : '',
      timeOut: formatTimeCardClock(open.last, timeZone),
      location: open.locationName,
      activity: 'On site',
      source: 'GPS',
      locationId: open.locationId,
    })
    open = null
  }

  for (const ping of ordered) {
    const locationId = ping.locationId?.trim()
    const locationName = ping.locationName?.trim()
    const seenUntil = ping.until ? laterIso(ping.at, ping.until) : ping.at
    if (!locationId || !locationName) {
      close()
      continue
    }
    if (ping.event === 'EXIT') {
      if (open?.locationId === locationId) {
        open.last = laterIso(open.last, ping.at)
      }
      else {
        close()
        open = { locationId, locationName, first: null, last: ping.at }
      }
      close()
      continue
    }
    if (ping.event !== 'ENTER' && open?.locationId === locationId) {
      open.last = laterIso(open.last, seenUntil)
      continue
    }
    close()
    open = { locationId, locationName, first: ping.at, last: seenUntil }
  }
  close()
  return dwells
}

/** Minutes either side of a site visit that a trip stop may sit and still belong to it. */
const GPS_TRIP_SLACK_MIN = 20

/**
 * Give trip stops the phone's real times at the site. Taps happen whenever
 * the driver gets to them; the crossing in and out of the site's circle is
 * when they actually arrived and left. Every trip stop at the site during one
 * visit shares it: the first takes the time in, the last the time out.
 */
export function alignTripStopsToGps(
  tripStops: readonly TimeCardStop[],
  gpsStops: readonly TimeCardStop[],
): TimeCardStop[] {
  const aligned = tripStops.map(stop => ({ ...stop }))
  for (const visit of gpsStops) {
    if (visit.source !== 'GPS' || !visit.locationId) continue
    const visitOut = minutesFromClock(visit.timeOut)
    const visitIn = minutesFromClock(visit.timeIn) ?? visitOut
    if (visitIn == null || visitOut == null) continue
    const during = aligned
      .filter((stop) => {
        if (stop.source !== 'TRIP' || stop.locationId !== visit.locationId) return false
        const stopIn = minutesFromClock(stop.timeIn)
        if (stopIn == null) return false
        const stopOut = minutesFromClock(stop.timeOut) ?? stopIn
        return stopIn <= visitOut + GPS_TRIP_SLACK_MIN && stopOut >= visitIn - GPS_TRIP_SLACK_MIN
      })
      .sort((a, b) => (minutesFromClock(a.timeIn) ?? 0) - (minutesFromClock(b.timeIn) ?? 0))
    const first = during[0]
    const last = during[during.length - 1]
    if (!first || !last) continue
    if (visit.timeIn) first.timeIn = visit.timeIn
    last.timeOut = visit.timeOut
  }
  return aligned
}

/**
 * Keep driver-corrected rows. Replace unedited auto rows. Append leftover
 * manual rows. GPS dwells that already sit inside a trip stop are dropped.
 */
export function mergeTimeCardStops(
  auto: readonly TimeCardStop[],
  saved: readonly TimeCardStop[],
): TimeCardStop[] {
  const savedByKey = new Map(saved.map(stop => [stop.key, stop]))
  const used = new Set<string>()
  const merged: TimeCardStop[] = []

  for (const row of auto) {
    const previous = savedByKey.get(row.key)
    if (previous?.corrected || previous?.source === 'MANUAL') {
      merged.push(previous)
    }
    else {
      merged.push(row)
    }
    used.add(row.key)
  }

  for (const row of saved) {
    if (used.has(row.key)) continue
    if (row.source === 'MANUAL' || row.corrected) merged.push(row)
  }

  const withoutCoveredGps = merged.filter((stop) => {
    if (stop.source !== 'GPS' || stop.corrected || !stop.locationId) return true
    return !merged.some(other =>
      other.source === 'TRIP'
      && other.locationId === stop.locationId
      && clocksOverlap(stop, other),
    )
  })

  return sortTimeCardStops(withoutCoveredGps).slice(0, TIME_CARD_STOP_MAX)
}

function clocksOverlap(a: TimeCardStop, b: TimeCardStop): boolean {
  const a0 = minutesFromClock(a.timeIn || a.timeOut)
  const b0 = minutesFromClock(b.timeIn || b.timeOut)
  if (a0 == null || b0 == null) return false
  const a1 = minutesFromClock(a.timeOut || a.timeIn) ?? a0
  const b1 = minutesFromClock(b.timeOut || b.timeIn) ?? b0
  return a0 <= b1 && b0 <= a1
}

export function matchPingToSite(
  ping: { latitude: number, longitude: number },
  sites: readonly TimeCardSite[],
  radiusMeters = TIME_CARD_GPS_RADIUS_M,
): TimeCardSite | null {
  let best: { site: TimeCardSite, meters: number } | null = null
  for (const site of sites) {
    if (site.latitude == null || site.longitude == null) continue
    const meters = haversineMeters(ping.latitude, ping.longitude, site.latitude, site.longitude)
    if (meters > radiusMeters) continue
    if (!best || meters < best.meters) best = { site, meters }
  }
  return best?.site ?? null
}

export function shouldKeepPing(
  ping: { latitude: number, longitude: number },
  previous: { latitude: number, longitude: number } | null,
): boolean {
  if (!previous) return true
  return haversineMeters(ping.latitude, ping.longitude, previous.latitude, previous.longitude) >= TIME_CARD_PING_MIN_GAP_M
}

export function shiftTotals(stops: readonly TimeCardStop[]): {
  reportForDuty: string
  releasedFromDuty: string
  totalOnDutyHours: string
} {
  const withTime = stops.filter(stop => stop.timeIn)
  const first = withTime[0]
  const last = withTime[withTime.length - 1]
  const reportForDuty = first?.timeIn ?? ''
  const releasedFromDuty = last?.timeOut || last?.timeIn || ''
  return {
    reportForDuty,
    releasedFromDuty,
    totalOnDutyHours: onDutyHoursLabel(reportForDuty, releasedFromDuty),
  }
}

/** Add up `H:MM` on-duty totals, for the preceding-7-days box. */
export function sumOnDutyHours(labels: readonly string[]): string {
  let minutes = 0
  for (const label of labels) {
    const match = /^(\d{1,3}):([0-5]\d)$/.exec(label.trim())
    if (!match) continue
    minutes += Number(match[1]) * 60 + Number(match[2])
  }
  if (!minutes) return ''
  return `${Math.floor(minutes / 60)}:${String(minutes % 60).padStart(2, '0')}`
}

export function applyHeaderOverrides<T extends Record<string, string>>(
  auto: T,
  saved: Partial<T> | null | undefined,
  overrides: readonly string[] | null | undefined,
): T {
  if (!saved || !overrides?.length) return auto
  const next = { ...auto }
  for (const field of overrides) {
    if (field in saved && typeof saved[field as keyof T] === 'string') {
      next[field as keyof T] = saved[field as keyof T] as T[keyof T]
    }
  }
  return next
}

export function routeCustomerFromTrips(trips: readonly TimeCardTripInput[]): string {
  const names: string[] = []
  const seen = new Set<string>()
  for (const trip of trips) {
    for (const value of [trip.customer, trip.destinationName, trip.originName]) {
      const name = value?.trim()
      if (!name || seen.has(name)) continue
      seen.add(name)
      names.push(name)
      if (names.length >= 3) return names.join(' / ')
    }
  }
  return names.join(' / ')
}

/** Every chassis used that day, in trip order, unique. */
export function trailerFromTrips(trips: readonly TimeCardTripInput[]): string {
  const ordered = [...trips].sort((a, b) => {
    const aAt = asDate(a.createdAt)?.getTime() ?? 0
    const bAt = asDate(b.createdAt)?.getTime() ?? 0
    return aAt - bAt || a.id.localeCompare(b.id)
  })
  const seen = new Set<string>()
  const plates: string[] = []
  for (const trip of ordered) {
    const plate = trip.chassisNumber?.trim()
    if (!plate || seen.has(plate)) continue
    seen.add(plate)
    plates.push(plate)
  }
  return plates.join(', ')
}

export function emptyTimeCardStops(): TimeCardStop[] {
  return []
}

export function isTimeCardWorkDate(value: string | null | undefined): value is string {
  return Boolean(value && TIME_CARD_DATE_RE.test(value.trim()))
}

export function blankTimeCardHeader(workDate: string): TimeCardHeader {
  return {
    driverName: '',
    date: formatTimeCardDate(workDate),
    truckUnit: '',
    trailerNumber: '',
    cdl: '',
    employeeId: '',
    dispatcher: '',
    routeCustomer: '',
    startOdometer: '',
    endOdometer: '',
    reportForDuty: '',
    releasedFromDuty: '',
    totalOnDutyHours: '',
    preceding7DayHours: '',
    signedName: '',
    signedDate: '',
  }
}


export function timeCardPdfFileName(workDate: string): string {
  return `time-card-${workDate}.pdf`
}

export function timeCardTemplateDocxFileName(): string {
  return 'Sensible-Logistics-short-haul-time-card.docx'
}

/** Blank unless the driver profile actually has a CDL number. */
export function cdlLabel(number?: string | null, state?: string | null): string {
  const id = number?.trim() || ''
  if (!id) return ''
  const st = state?.trim() || ''
  return st ? `${id} / ${st}` : id
}

export function normalizeVin(value: string | null | undefined): string {
  return String(value || '').replace(/[^A-Za-z0-9]/g, '').toUpperCase()
}

export function normalizeTimeCardClock(value: string): string {
  const minutes = minutesFromClock(value)
  if (minutes == null) return ''
  const hours = Math.floor(minutes / 60) % 24
  const rest = minutes % 60
  return `${String(hours).padStart(2, '0')}:${String(rest).padStart(2, '0')}`
}

export function newManualTimeCardStop(): TimeCardStop {
  const key = `MANUAL:${Date.now().toString(36)}:${Math.random().toString(36).slice(2, 8)}`
  return {
    key,
    timeIn: '',
    timeOut: '',
    location: '',
    activity: '',
    source: 'MANUAL',
    corrected: true,
  }
}

export function sanitizeTimeCardStop(input: Partial<TimeCardStop> | null | undefined): TimeCardStop | null {
  if (!input) return null
  const key = String(input.key || '').trim().slice(0, 80)
  if (!key) return null
  const source = TIME_CARD_STOP_SOURCES.includes(input.source as TimeCardStopSource)
    ? input.source as TimeCardStopSource
    : 'MANUAL'
  return {
    key,
    timeIn: normalizeTimeCardClock(String(input.timeIn || '')),
    timeOut: normalizeTimeCardClock(String(input.timeOut || '')),
    location: String(input.location || '').trim().slice(0, 120),
    activity: String(input.activity || '').trim().slice(0, 80),
    source,
    tripId: input.tripId ? String(input.tripId).slice(0, 80) : null,
    locationId: input.locationId ? String(input.locationId).slice(0, 80) : null,
    customer: input.customer ? String(input.customer).trim().slice(0, 120) : null,
    corrected: Boolean(input.corrected) || source === 'MANUAL',
  }
}

function pingDistance(
  a: { latitude: number, longitude: number },
  b: { latitude: number, longitude: number },
): number {
  return haversineMeters(a.latitude, a.longitude, b.latitude, b.longitude)
}

/** Keep a dwell alive by refreshing the last ping, otherwise append. */
export function mergeIncomingPing(
  pings: readonly TimeCardPing[],
  ping: TimeCardPing,
): TimeCardPing[] {
  const last = pings[pings.length - 1]
  // Crossings are never folded: their exact time is the point of them.
  if (last && !last.event && !ping.event && pingDistance(last, ping) < TIME_CARD_PING_MIN_GAP_M) {
    const next = [...pings]
    next[next.length - 1] = {
      ...last,
      until: laterIso(last.until ?? last.at, ping.until ?? ping.at),
      accuracyMeters: ping.accuracyMeters ?? last.accuracyMeters,
      locationId: ping.locationId ?? last.locationId,
      locationName: ping.locationName ?? last.locationName,
    }
    return next
  }
  const next = [...pings, ping]
  return next.length > TIME_CARD_PING_MAX ? next.slice(next.length - TIME_CARD_PING_MAX) : next
}

export function annotatePingsWithSites(
  pings: readonly TimeCardPing[],
  sites: readonly TimeCardSite[],
): TimeCardPing[] {
  const byId = new Map(sites.map(site => [site.id, site]))
  return pings.map((ping) => {
    // A crossing names its site: the phone was watching that site's circle.
    const crossed = ping.event && ping.locationId ? byId.get(ping.locationId) : null
    if (crossed) {
      return { ...ping, locationName: formatTimeCardLocation(crossed.name, crossed.city, crossed.state) }
    }
    if (ping.accuracyMeters != null && ping.accuracyMeters > TIME_CARD_GPS_ACCURACY_MAX_M) {
      return { ...ping, locationId: null, locationName: null }
    }
    const site = matchPingToSite(ping, sites)
    return {
      ...ping,
      locationId: site?.id ?? null,
      locationName: site ? formatTimeCardLocation(site.name, site.city, site.state) : null,
    }
  })
}

export function markStopCorrections(
  submitted: readonly TimeCardStop[],
  auto: readonly TimeCardStop[],
): TimeCardStop[] {
  const autoByKey = new Map(auto.map(stop => [stop.key, stop]))
  return submitted.map((row) => {
    const base = autoByKey.get(row.key)
    if (!base) {
      return { ...row, source: row.source === 'GPS' ? 'GPS' : 'MANUAL', corrected: true }
    }
    const changed = row.timeIn !== base.timeIn
      || row.timeOut !== base.timeOut
      || row.location !== base.location
      || row.activity !== base.activity
      || (row.customer ?? null) !== (base.customer ?? null)
    return {
      ...base,
      timeIn: row.timeIn,
      timeOut: row.timeOut,
      location: row.location,
      activity: row.activity,
      customer: row.customer ?? null,
      // The auto baseline already carries whatever `locationId` the trip
      // correction (if any) just settled on; a submitted id is only ever
      // trusted here when the correction was rejected and `base` still
      // reflects the un-corrected trip, so the display and the id it
      // would resubmit next time stay in step with each other.
      locationId: row.locationId ?? base.locationId,
      corrected: changed || Boolean(row.corrected),
    }
  })
}

export function headerOverrideFields(
  auto: TimeCardHeader,
  submitted: Partial<TimeCardHeader>,
): TimeCardHeaderField[] {
  const fields: TimeCardHeaderField[] = []
  for (const field of TIME_CARD_HEADER_FIELDS) {
    if (field in submitted && submitted[field] !== auto[field]) fields.push(field)
  }
  return fields
}

/** First and next midnight of a calendar date in an IANA zone, as UTC instants. */
export function zonedDayRange(isoDate: string, timeZone: string): { start: Date, end: Date } {
  const start = zonedMidnight(isoDate, timeZone)
  const end = zonedMidnight(addIsoDays(isoDate, 1), timeZone)
  return { start, end }
}

function zonedMidnight(isoDate: string, timeZone: string): Date {
  const [year, month, day] = isoDate.split('-').map(Number)
  let lo = Date.UTC(year!, month! - 1, day!) - 16 * 3600 * 1000
  let hi = Date.UTC(year!, month! - 1, day!) + 16 * 3600 * 1000
  while (hi - lo > 500) {
    const mid = Math.floor((lo + hi) / 2)
    if (calendarDateInZone(new Date(mid), timeZone) < isoDate) lo = mid
    else hi = mid
  }
  return new Date(hi)
}
