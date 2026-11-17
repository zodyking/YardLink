import { and, asc, eq, isNull } from 'drizzle-orm'
import { autoSiteRadius, type BoundingBox } from '#shared/utils/geo'
import { formatAddressSearchQuery } from '#shared/utils/us-address'
import { locations } from '../database/schema'
import { useGeocoder } from './geocoding'

type Db = ReturnType<typeof useDb>

export interface PlacedSite {
  latitude: number
  longitude: number
  arrivalRadiusM: number
}

interface Address {
  addressLine1?: string | null
  city?: string | null
  state?: string | null
  postalCode?: string | null
}

const same = (a: string | null | undefined, b: string | null | undefined) =>
  (a ?? '').trim().toLowerCase() === (b ?? '').trim().toLowerCase()

/**
 * Put a site on the map from its address alone: the point the address
 * resolves to, and a circle sized to cover it. Answers null when the address
 * is incomplete, is not found, or resolves to a different state than the one
 * given, so a wrong guess never becomes an active pin.
 */
export async function placeSite(type: string, address: Address): Promise<PlacedSite | null> {
  if (!address.addressLine1?.trim()) return null
  if (!address.postalCode?.trim() && !(address.city?.trim() && address.state?.trim())) return null

  const found = await useGeocoder().search(formatAddressSearchQuery(address), 3)
  const hit = found.results.find(result => !address.state?.trim() || same(result.state, address.state))
  if (!hit) return null

  const outline: BoundingBox | null = hit.bbox
  return {
    latitude: hit.latitude,
    longitude: hit.longitude,
    arrivalRadiusM: autoSiteRadius(type, outline),
  }
}

/** Addresses already tried since this server started, so a bad one is not retried every minute. */
const tried = new Set<string>()
let running = false

const BATCH = 25
/** The public geocoder asks for no more than about one request a second. */
const PAUSE_MS = 1_100

/**
 * Give every site that has an address but no pin one. Covers a freshly
 * imported spreadsheet and sites made before pins were automatic.
 */
export async function placeUnpinnedSites(db: Db): Promise<number> {
  if (running) return 0
  running = true
  let placed = 0
  try {
    const rows = await db
      .select({
        id: locations.id,
        type: locations.type,
        addressLine1: locations.addressLine1,
        city: locations.city,
        state: locations.state,
        postalCode: locations.postalCode,
      })
      .from(locations)
      .where(and(isNull(locations.latitude), isNull(locations.deletedAt), eq(locations.isUncategorized, false)))
      .orderBy(asc(locations.createdAt))
      .limit(BATCH + tried.size)

    let looked = 0
    for (const row of rows) {
      if (tried.has(row.id) || !row.addressLine1) continue
      if (looked >= BATCH) break
      if (looked > 0) await new Promise(resolve => setTimeout(resolve, PAUSE_MS))
      looked++

      const site = await placeSite(row.type, row)
      if (!site) {
        tried.add(row.id)
        continue
      }
      await db
        .update(locations)
        .set({
          latitude: String(site.latitude),
          longitude: String(site.longitude),
          arrivalRadiusM: site.arrivalRadiusM,
          updatedAt: new Date(),
        })
        .where(and(eq(locations.id, row.id), isNull(locations.latitude)))
      placed++
    }
  }
  finally {
    running = false
  }
  return placed
}
