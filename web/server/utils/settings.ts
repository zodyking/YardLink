import { eq } from 'drizzle-orm'
import { companies } from '../database/schema'
import type { DbExecutor } from './db'
import { loadPrimaryCompany } from './company'

/**
 * Employer-editable configuration, stored in `companies.settings` and managed
 * from Settings in the web app. Environment variables are only a fallback for
 * installs that were configured that way before Yard Link.
 */
export interface CompanySettings {
  /** Address phones use to reach this server, e.g. https://yard.example.com */
  publicUrl: string
  shipcsxDefaultTerminal: string
  shipcsxPoll: boolean
  /** New accounts wait for a dispatcher to approve them. */
  approveNewAccounts: boolean
  /** Shows Bridge Crossing Times under Tools, for the Hudson River crossings. */
  bridgeCrossingTimesEnabled: boolean
  /**
   * Printed on the time card PDF in place of the baked-in placeholder
   * numbers/address that shipped with the template. All blank by default —
   * left off the PDF entirely rather than guessed, since this prints on an
   * official DOT form.
   */
  timeCardOfficePhone: string
  timeCardDispatchPhone: string
  timeCardReportingLocation: string
}

const DEFAULTS: CompanySettings = {
  publicUrl: '',
  shipcsxDefaultTerminal: '',
  shipcsxPoll: false,
  approveNewAccounts: true,
  bridgeCrossingTimesEnabled: false,
  timeCardOfficePhone: '',
  timeCardDispatchPhone: '',
  timeCardReportingLocation: '',
}

let cached: CompanySettings = { ...DEFAULTS }
let cachedAt = 0
const TTL_MS = 15_000

function text(value: unknown): string {
  return typeof value === 'string' ? value.trim() : ''
}

export function cleanPublicUrl(value: unknown): string {
  const raw = text(value).replace(/\/+$/, '')
  if (!raw) return ''
  try {
    const url = new URL(/^https?:\/\//i.test(raw) ? raw : `https://${raw}`)
    if (url.protocol !== 'http:' && url.protocol !== 'https:') return ''
    return `${url.protocol}//${url.host}`
  }
  catch {
    return ''
  }
}

export function settingsFromRow(raw: Record<string, unknown> | null | undefined): CompanySettings {
  const row = raw ?? {}
  return {
    publicUrl: cleanPublicUrl(row.publicUrl),
    shipcsxDefaultTerminal: text(row.shipcsxDefaultTerminal) || text(process.env.NUXT_SHIPCSX_DEFAULT_TERMINAL),
    shipcsxPoll: typeof row.shipcsxPoll === 'boolean'
      ? row.shipcsxPoll
      : text(process.env.NUXT_SHIPCSX_POLL).toLowerCase() === 'true',
    approveNewAccounts: typeof row.approveNewAccounts === 'boolean' ? row.approveNewAccounts : DEFAULTS.approveNewAccounts,
    bridgeCrossingTimesEnabled: typeof row.bridgeCrossingTimesEnabled === 'boolean'
      ? row.bridgeCrossingTimesEnabled
      : DEFAULTS.bridgeCrossingTimesEnabled,
    timeCardOfficePhone: text(row.timeCardOfficePhone),
    timeCardDispatchPhone: text(row.timeCardDispatchPhone),
    timeCardReportingLocation: text(row.timeCardReportingLocation),
  }
}

export async function loadCompanySettings(db: DbExecutor, options: { fresh?: boolean } = {}): Promise<CompanySettings> {
  if (!options.fresh && Date.now() - cachedAt < TTL_MS) return cached
  const company = await loadPrimaryCompany(db)
  cached = settingsFromRow(company?.settings)
  cachedAt = Date.now()
  return cached
}

/** Last loaded values, for synchronous callers. Refreshed on every load and save. */
export function peekCompanySettings(): CompanySettings {
  return cached
}

export async function saveCompanySettings(
  db: DbExecutor,
  companyId: string,
  patch: Partial<CompanySettings>,
): Promise<CompanySettings> {
  const [row] = await db.select({ settings: companies.settings }).from(companies).where(eq(companies.id, companyId)).limit(1)
  const next: Record<string, unknown> = { ...(row?.settings ?? {}) }
  if (patch.publicUrl !== undefined) next.publicUrl = cleanPublicUrl(patch.publicUrl)
  if (patch.shipcsxDefaultTerminal !== undefined) next.shipcsxDefaultTerminal = text(patch.shipcsxDefaultTerminal)
  if (patch.shipcsxPoll !== undefined) next.shipcsxPoll = patch.shipcsxPoll
  if (patch.approveNewAccounts !== undefined) next.approveNewAccounts = patch.approveNewAccounts
  if (patch.bridgeCrossingTimesEnabled !== undefined) next.bridgeCrossingTimesEnabled = patch.bridgeCrossingTimesEnabled
  if (patch.timeCardOfficePhone !== undefined) next.timeCardOfficePhone = text(patch.timeCardOfficePhone)
  if (patch.timeCardDispatchPhone !== undefined) next.timeCardDispatchPhone = text(patch.timeCardDispatchPhone)
  if (patch.timeCardReportingLocation !== undefined) next.timeCardReportingLocation = text(patch.timeCardReportingLocation)
  await db.update(companies).set({ settings: next, updatedAt: new Date() }).where(eq(companies.id, companyId))
  cached = settingsFromRow(next)
  cachedAt = Date.now()
  return cached
}

/**
 * Address to put in the employer connection code: the configured public
 * address, or the one this request arrived on.
 */
export function serverAddressFor(settings: CompanySettings, requestOrigin: string): string {
  return settings.publicUrl || requestOrigin.replace(/\/+$/, '')
}
