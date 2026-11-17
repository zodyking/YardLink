/**
 * Geographic helpers for sites and fixes.
 *
 * A site is a point and a radius in metres. Bounding boxes are
 * west/south/east/north in WGS 84, used for map views and geocoder extents.
 * Distances use the haversine formula.
 */

export interface BoundingBox {
  west: number
  south: number
  east: number
  north: number
}

const METERS_PER_DEG_LAT = 110540

function metersPerDegLon(latitude: number): number {
  return 111320 * Math.cos((latitude * Math.PI) / 180)
}

export function isValidBbox(box: BoundingBox): boolean {
  return box.west < box.east
    && box.south < box.north
    && box.west >= -180 && box.east <= 180
    && box.south >= -90 && box.north <= 90
}

/** Coerce API/database numeric strings into a finite WGS 84 component. */
export function parseCoord(value: number | string | null | undefined): number | null {
  if (value == null || value === '') return null
  const n = typeof value === 'number' ? value : Number(String(value).trim())
  return Number.isFinite(n) ? n : null
}

/** Site pin. Rejects missing values, non-numeric strings, and the 0,0 placeholder. */
export function parsePin(
  latitude: number | string | null | undefined,
  longitude: number | string | null | undefined,
): { latitude: number, longitude: number } | null {
  const lat = parseCoord(latitude)
  const lng = parseCoord(longitude)
  if (lat == null || lng == null) return null
  if (lat === 0 && lng === 0) return null
  if (lat < -90 || lat > 90 || lng < -180 || lng > 180) return null
  return { latitude: lat, longitude: lng }
}

/** Photon country codes and display names for United States results. */
export function isUnitedStatesCountry(value: string | null | undefined): boolean {
  const raw = String(value ?? '').trim().toUpperCase().replace(/\./g, '')
  if (!raw) return false
  return raw === 'US' || raw === 'USA' || raw === 'UNITED STATES' || raw === 'UNITED STATES OF AMERICA'
}

/** Photon/Nominatim extents arrive in mixed corner order — min/max is safer. */
export function bboxFromExtent(extent: number[]): BoundingBox | null {
  if (extent.length < 4) return null
  const [a, b, c, d] = extent
  if (![a, b, c, d].every(n => Number.isFinite(n))) return null
  const west = Math.min(a!, c!)
  const east = Math.max(a!, c!)
  const south = Math.min(b!, d!)
  const north = Math.max(b!, d!)
  const box = { west, south, east, north }
  return isValidBbox(box) ? box : null
}

export function bboxAround(latitude: number, longitude: number, halfMeters = 160): BoundingBox {
  const dLat = halfMeters / METERS_PER_DEG_LAT
  const dLon = halfMeters / Math.max(metersPerDegLon(latitude), 1)
  return {
    west: longitude - dLon,
    east: longitude + dLon,
    south: latitude - dLat,
    north: latitude + dLat,
  }
}

export function bboxCenter(box: BoundingBox): { latitude: number, longitude: number } {
  return {
    latitude: (box.north + box.south) / 2,
    longitude: (box.west + box.east) / 2,
  }
}

/** Local metres east/north of the south-west corner. */
export function offsetLatLng(latitude: number, longitude: number, eastMeters: number, northMeters: number): { latitude: number, longitude: number } {
  return {
    latitude: latitude + northMeters / METERS_PER_DEG_LAT,
    longitude: longitude + eastMeters / Math.max(metersPerDegLon(latitude), 1),
  }
}

/** Clockwise heading in degrees from north, 0–360. */
export function bearingDeg(
  fromLat: number,
  fromLng: number,
  toLat: number,
  toLng: number,
): number {
  const φ1 = (fromLat * Math.PI) / 180
  const φ2 = (toLat * Math.PI) / 180
  const Δλ = ((toLng - fromLng) * Math.PI) / 180
  const y = Math.sin(Δλ) * Math.cos(φ2)
  const x = Math.cos(φ1) * Math.sin(φ2) - Math.sin(φ1) * Math.cos(φ2) * Math.cos(Δλ)
  return (((Math.atan2(y, x) * 180) / Math.PI) % 360 + 360) % 360
}

export function haversineMeters(
  lat1: number,
  lng1: number,
  lat2: number,
  lng2: number,
): number {
  const R = 6371000
  const φ1 = (lat1 * Math.PI) / 180
  const φ2 = (lat2 * Math.PI) / 180
  const Δφ = ((lat2 - lat1) * Math.PI) / 180
  const Δλ = ((lng2 - lng1) * Math.PI) / 180
  const a = Math.sin(Δφ / 2) ** 2 + Math.cos(φ1) * Math.cos(φ2) * Math.sin(Δλ / 2) ** 2
  return 2 * R * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
}

/**
 * Pick the street heading or its reverse, whichever is closer to the current
 * rotation, so Align-to-street does not flip the door 180° unless needed.
 */
export function pointInBbox(latitude: number, longitude: number, box: BoundingBox): boolean {
  return longitude >= box.west && longitude <= box.east && latitude >= box.south && latitude <= box.north
}

/** Ray-casting on a GeoJSON ring of [lng, lat] pairs. */
export function clampLatLngToBbox(latitude: number, longitude: number, box: BoundingBox): { latitude: number, longitude: number } {
  return {
    latitude: Math.min(box.north, Math.max(box.south, latitude)),
    longitude: Math.min(box.east, Math.max(box.west, longitude)),
  }
}

/** Is this fix inside the site's circle? */
export function withinRadius(
  point: { latitude: number, longitude: number },
  site: { latitude: number, longitude: number },
  radiusMeters: number,
): boolean {
  return haversineMeters(point.latitude, point.longitude, site.latitude, site.longitude) <= radiusMeters
}

/** How far a site's circle reaches, kept inside what the app allows. */
export const SITE_RADIUS_MIN_M = 40
export const SITE_RADIUS_MAX_M = 2000
export const SITE_RADIUS_DEFAULT_M = 180

export function clampSiteRadius(meters: number | null | undefined): number {
  if (!Number.isFinite(meters ?? NaN)) return SITE_RADIUS_DEFAULT_M
  return Math.min(SITE_RADIUS_MAX_M, Math.max(SITE_RADIUS_MIN_M, Math.round(meters as number)))
}

/** The circle a kind of site needs when nothing says how big it is. */
const SITE_RADIUS_BY_TYPE: Record<string, number> = {
  MARINE_TERMINAL: 600,
  RAIL_TERMINAL: 500,
  COMPANY_YARD: 220,
  CUSTOMER: 140,
}

/**
 * How big a site's circle should be so a truck at its gate is inside it.
 * When the address came back with an outline (a building or a terminal's
 * grounds), the circle reaches its far corner; otherwise it is the usual
 * size for that kind of site. Never smaller than half the usual size, so a
 * tiny outline still catches a driver waiting at the street.
 */
export function autoSiteRadius(type: string, outline?: BoundingBox | null): number {
  const usual = SITE_RADIUS_BY_TYPE[type] ?? SITE_RADIUS_DEFAULT_M
  if (!outline || !isValidBbox(outline)) return clampSiteRadius(usual)
  const centre = bboxCenter(outline)
  const reach = haversineMeters(centre.latitude, centre.longitude, outline.north, outline.east)
  const sized = Math.max(reach * 1.15, usual / 2)
  return clampSiteRadius(Math.round(sized / 10) * 10)
}

/** Has a site been given a usable point? */
export function isPlacedPin(
  latitude: number | string | null | undefined,
  longitude: number | string | null | undefined,
): boolean {
  return parsePin(latitude, longitude) != null
}
