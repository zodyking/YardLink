import { eq } from 'drizzle-orm'
import { locations } from '../../database/schema'
import { listOpenCsxReleases } from '../../services/csx-releases'
import { listOnSiteChassis, listOnSiteContainers } from '../../services/location-equipment'
import { listLocationNotes } from '../../services/location-notes'
import { locationIdsAtSameAddress } from '../../services/location-sites'
import { assertTenant, requireAuth } from '../../utils/session'
import { countContainersByType, emptyTypeCounts } from '#shared/utils/domain'
import { parseCoord } from '#shared/utils/geo'

/** One location plus the active-pool containers currently on site. */
export default defineEventHandler(async (event) => {
  const auth = await requireAuth(event)
  const id = getRouterParam(event, 'id')
  const query = getQuery(event)
  const sameAddress = query.sameAddress === '1' || query.sameAddress === 'true'

  if (!id) {
    throw createError({ statusCode: 400, statusMessage: 'Location id is required.' })
  }

  const db = useDb()

  const [location] = await db.select().from(locations).where(eq(locations.id, id)).limit(1)
  assertTenant(auth, location, 'Location')
  if (location!.deletedAt) {
    throw createError({ statusCode: 404, statusMessage: 'Location not found.' })
  }

  const locationIds = sameAddress
    ? await locationIdsAtSameAddress(db, auth.companyId, id)
    : [id]

  const mapped = await listOnSiteContainers(db, auth.companyId, locationIds)
  const chassisRows = await listOnSiteChassis(db, auth.companyId, locationIds)

  return {
    location: {
      id: location!.id,
      name: location!.name,
      type: location!.type,
      addressLine1: location!.addressLine1,
      city: location!.city,
      state: location!.state,
      postalCode: location!.postalCode,
      capacity: location!.capacity,
      latitude: parseCoord(location!.latitude),
      longitude: parseCoord(location!.longitude),
      arrivalRadiusM: location!.arrivalRadiusM,
      hours: location!.hours,
      mainPhone: location!.mainPhone,
      contactName: location!.contactName,
      contactPhone: location!.contactPhone,
      gateInstructions: location!.gateInstructions,
      driverNotes: location!.driverNotes,
      shipcsxTerminal: location!.shipcsxTerminal,
      isUncategorized: location!.isUncategorized,
    },
    typeCounts: mapped.length ? countContainersByType(mapped) : emptyTypeCounts(),
    occupancy: mapped.length,
    containers: mapped,
    chassis: chassisRows,
    csxReleases: await listOpenCsxReleases(db, auth.companyId, locationIds),
    notes: await listLocationNotes(db, auth, id),
  }
})
