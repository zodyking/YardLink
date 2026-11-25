import { and, eq, sql } from 'drizzle-orm'
import { companies, companyMemberships, containers, drivers, locations, trucks } from '../../database/schema'
import { useGeocoder } from '../../services/geocoding'
import { formatInviteCode } from '../../utils/company'
import { databaseStatus } from '../../utils/database-config'
import { currentDatabaseUrl } from '../../utils/db'
import { loadCompanySettings } from '../../utils/settings'
import { loadSmtpConfig, summarizeSmtp } from '../../utils/smtp-settings'
import { loadPushConfig, summarizePush } from '../../utils/push-settings'
import { useOcrService } from '../../services/ocr'
import { useDocScanWorker } from '../../services/docscan'
import { useObjectStorage } from '../../services/storage'
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

  const [ocr, docscan, storage, geocoder] = await Promise.all([
    useOcrService().healthCheck(),
    useDocScanWorker().health(),
    useObjectStorage().healthCheck(),
    useGeocoder().healthCheck(),
  ])

  const smtp = await loadSmtpConfig(db)
  const apns = await loadPushConfig(db)

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
    email: summarizeSmtp(smtp),
    push: summarizePush(apns),
    database: databaseStatus(currentDatabaseUrl()),
    counts: { ...counts, admins: adminCount?.value ?? 0 },
    services: [
      { key: 'ocr', name: 'OpenOCR (RepViT DB + RepSVTR Mobile)', healthy: ocr.healthy, detail: ocr.message, phase: 'Phase 1' },
      { key: 'docscan', name: 'Document scan cleanup', healthy: docscan.healthy, detail: docscan.message, phase: 'Built in' },
      { key: 'storage', name: 'Photos and documents', healthy: storage.healthy, detail: storage.message, phase: 'Built in' },
      { key: 'messages', name: 'Messages', healthy: true, detail: 'Drivers and dispatch talk inside Yard Link. No SMS service is used.', phase: 'Built in' },
      {
        key: 'email',
        name: 'Email',
        healthy: Boolean(smtp),
        detail: smtp
          ? `Sending as ${smtp.fromEmail} through ${smtp.host}.`
          : 'Not set up. New accounts are not asked to confirm an address and nobody is emailed.',
        phase: 'Optional',
      },
      {
        key: 'push',
        name: 'Push notifications',
        healthy: Boolean(apns),
        detail: apns
          ? `Sending to ${apns.bundleId} with key ${apns.keyId}${apns.sandbox ? ' (Apple sandbox)' : ''}.`
          : 'Not set up. Phones see messages and work when the app is open.',
        phase: 'Optional',
      },
      { key: 'geocoder', name: 'OpenStreetMap / Photon', healthy: geocoder.healthy, detail: geocoder.message, phase: 'Phase 1' },
      { key: 'tiles', name: 'Planetiler / PMTiles vector tiles', healthy: false, detail: 'Regional tile archive not generated yet.', phase: 'Phase 2' },
      { key: 'realtime', name: 'WebSocket live updates', healthy: false, detail: 'Polling is used in Phase 1.', phase: 'Phase 2' },
      { key: 'jobs', name: 'pg-boss background jobs', healthy: false, detail: 'Job queue not enabled in Phase 1.', phase: 'Phase 2' },
    ],
  }
})
