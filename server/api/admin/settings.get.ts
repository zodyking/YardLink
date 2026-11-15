import { and, eq, sql } from 'drizzle-orm'
import { companies, companyMemberships, containers, drivers, locations, trucks } from '../../database/schema'
import { useGeocoder } from '../../services/geocoding'
import { formatInviteCode } from '../../utils/company'
import { loadCompanySettings } from '../../utils/settings'
import { SHIPCSX_TERMINALS } from '#shared/utils/csx-lookup'
import { useOcrService } from '../../services/ocr'
import { useObjectStorage } from '../../services/storage'
import { shipcsxHealth } from '../../services/shipcsx-poll'
import { requireAdmin } from '../../utils/session'

/** Company settings plus the deployment status of each self-hosted subsystem. */
export default defineEventHandler(async (event) => {
  const auth = await requireAdmin(event)
  const db = useDb()

  const [company] = await db.select().from(companies).where(eq(companies.id, auth.companyId)).limit(1)

  if (!company) {
    throw createError({ statusCode: 404, statusMessage: 'Company not found.' })
  }

  const [counts] = await db
    .select({
      containers: sql<number>`(select count(*)::int from ${containers} where company_id = ${auth.companyId})`,
      activeContainers: sql<number>`(select count(*)::int from ${containers} where company_id = ${auth.companyId} and active_pool_state <> 'INACTIVE')`,
      locations: sql<number>`(select count(*)::int from ${locations} where company_id = ${auth.companyId} and deleted_at is null)`,
      drivers: sql<number>`(select count(*)::int from ${drivers} where company_id = ${auth.companyId})`,
      trucks: sql<number>`(select count(*)::int from ${trucks} where company_id = ${auth.companyId})`,
      admins: sql<number>`(select count(*)::int from ${companyMemberships} where company_id = ${auth.companyId} and role = 'ADMIN')`,
    })
    .from(companies)
    .where(eq(companies.id, auth.companyId))
    .limit(1)

  const [ocr, storage, geocoder, shipcsx] = await Promise.all([
    useOcrService().healthCheck(),
    useObjectStorage().healthCheck(),
    useGeocoder().healthCheck(),
    shipcsxHealth(db, auth.companyId),
  ])

  const [adminCount] = await db
    .select({ value: sql<number>`count(*)::int` })
    .from(companyMemberships)
    .where(and(eq(companyMemberships.companyId, auth.companyId), eq(companyMemberships.role, 'ADMIN')))

  return {
    company: {
      id: company.id,
      name: company.name,
      legalName: company.legalName,
      usdotNumber: company.usdotNumber,
      timezone: company.timezone,
      inviteCode: formatInviteCode(company.inviteCode),
    },
    settings: await loadCompanySettings(db, { fresh: true }),
    shipcsxTerminals: SHIPCSX_TERMINALS,
    counts: { ...counts, admins: adminCount?.value ?? 0 },
    services: [
      { key: 'ocr', name: 'OpenOCR (RepViT DB + RepSVTR Mobile)', healthy: ocr.healthy, detail: ocr.message, phase: 'Phase 1' },
      { key: 'storage', name: 'Photos and documents', healthy: storage.healthy, detail: storage.message, phase: 'Built in' },
      { key: 'messages', name: 'Messages', healthy: true, detail: 'Drivers and dispatch talk inside Yard Link. No mail or SMS service is used.', phase: 'Built in' },
      { key: 'geocoder', name: 'OpenStreetMap / Photon', healthy: geocoder.healthy, detail: geocoder.message, phase: 'Phase 1' },
      { key: 'tiles', name: 'Planetiler / PMTiles vector tiles', healthy: false, detail: 'Regional tile archive not generated yet.', phase: 'Phase 2' },
      { key: 'realtime', name: 'WebSocket live updates', healthy: false, detail: 'Polling is used in Phase 1.', phase: 'Phase 2' },
      { key: 'jobs', name: 'pg-boss background jobs', healthy: false, detail: 'Job queue not enabled in Phase 1.', phase: 'Phase 2' },
      {
        key: 'shipcsx',
        name: 'ShipCSX lookup',
        healthy: !shipcsx.lastError,
        detail: shipcsx.lastError
          || (shipcsx.lastFinishedAt
            ? `Last check ${shipcsx.lastFinishedAt.toISOString()} · ${shipcsx.checkedCount} boxes`
            : 'No check yet. Turn on automatic checks below, or check a container.'),
        phase: 'Phase 1',
      },
    ],
  }
})
