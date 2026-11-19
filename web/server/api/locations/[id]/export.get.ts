import { eq } from 'drizzle-orm'
import { locations } from '../../../database/schema'
import { listOnSiteChassis, listOnSiteContainers } from '../../../services/location-equipment'
import { listLocationNotes } from '../../../services/location-notes'
import { locationIdsAtSameAddress } from '../../../services/location-sites'
import { assertTenant, requireAuth } from '../../../utils/session'
import { formatLocationExportList } from '#shared/utils/location-export'

/**
 * The same text a dispatcher gets from the web app's "Export list" sheet on
 * a location, generated the same way (shared formatter) so the phone and
 * the console always produce byte-identical output. The phone has no
 * reason to reimplement the masking and layout rules in Swift.
 */
export default defineEventHandler(async (event) => {
  const auth = await requireAuth(event)
  const id = getRouterParam(event, 'id')
  const query = getQuery(event)
  const sameAddress = query.sameAddress === '1' || query.sameAddress === 'true'
  const includeNotes = query.includeNotes === '1' || query.includeNotes === 'true'

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

  const containers = await listOnSiteContainers(db, auth.companyId, locationIds)
  const chassis = await listOnSiteChassis(db, auth.companyId, locationIds)
  const notes = await listLocationNotes(db, auth, id)

  const text = formatLocationExportList({
    locationName: location!.name,
    containers,
    chassis,
    notes,
    includeNotes,
  })

  return { text, noteCount: notes.length }
})
