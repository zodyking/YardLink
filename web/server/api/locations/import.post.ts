import { and, eq, isNull, sql } from 'drizzle-orm'
import { z } from 'zod'
import { parseLocationImport } from '#shared/utils/location-import'
import type { LocationImportIssue } from '#shared/utils/location-import'
import { toE164 } from '#shared/utils/phone'
import { locations } from '../../database/schema'
import { normalizeAddress } from '../../services/geocoding'
import { requireAdmin } from '../../utils/session'

const schema = z.object({
  csv: z.string().min(1, 'Choose a file to import.').max(2_000_000, 'This file is too large. Split it and import it in parts.'),
})

/**
 * Add many locations at once from a spreadsheet (CSV) in the layout the
 * location export writes. A location whose name is already in the pool is
 * left as it is, so importing the same file twice adds nothing the second
 * time. Rows that cannot be read are reported and the rest are saved.
 */
export default defineEventHandler(async (event) => {
  const auth = await requireAdmin(event)
  const body = await readValidatedJson(event, schema)

  const parsed = parseLocationImport(body.csv)
  if (parsed.fileError) {
    throw createError({ statusCode: 422, statusMessage: parsed.fileError })
  }

  const db = useDb()
  const existing = await db
    .select({ name: sql<string>`lower(${locations.name})` })
    .from(locations)
    .where(and(eq(locations.companyId, auth.companyId), isNull(locations.deletedAt)))
  const taken = new Set(existing.map(row => row.name))

  const skipped: LocationImportIssue[] = []
  const fresh = parsed.rows.filter((row) => {
    if (!taken.has(row.name.toLowerCase())) return true
    skipped.push({ line: row.line, name: row.name, message: 'Already in your locations.' })
    return false
  })

  if (fresh.length) {
    await db.insert(locations).values(fresh.map(row => ({
      companyId: auth.companyId,
      name: row.name,
      type: row.type,
      locationCode: row.locationCode,
      addressLine1: row.addressLine1,
      addressLine2: row.addressLine2,
      city: row.city,
      state: row.state,
      postalCode: row.postalCode,
      country: 'US',
      normalizedAddress: normalizeAddress(row),
      latitude: row.latitude !== null ? String(row.latitude) : null,
      longitude: row.longitude !== null ? String(row.longitude) : null,
      capacity: row.capacity,
      hours: row.hours,
      appointmentRequired: row.appointmentRequired,
      mainPhone: row.mainPhone ? toE164(row.mainPhone) : null,
      contactName: row.contactName,
      contactPhone: row.contactPhone ? toE164(row.contactPhone) : null,
      gateInstructions: row.gateInstructions,
      driverNotes: row.driverNotes,
      shipcsxTerminal: row.shipcsxTerminal,
      status: row.status,
      createdByUserId: auth.userId,
    })))
  }

  return {
    ok: true,
    created: fresh.length,
    skipped,
    errors: parsed.errors,
    warnings: parsed.warnings,
  }
})
