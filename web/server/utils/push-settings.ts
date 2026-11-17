import { eq } from 'drizzle-orm'
import { z } from 'zod'
import { companies } from '../database/schema'
import { loadPrimaryCompany } from './company'
import type { DbExecutor } from './db'
import { openSecret, sealSecret } from './secret-box'

/**
 * Apple Push Notification settings, entered under Settings and kept with the
 * company's other settings. The signing key is stored sealed and is never
 * sent back to a browser.
 */
export interface PushConfig {
  keyId: string
  teamId: string
  bundleId: string
  /** The .p8 file's text, including the BEGIN/END lines. */
  signingKey: string
  /** Apple's sandbox is for builds signed with a development profile. */
  sandbox: boolean
}

/** What the web app is allowed to see. */
export interface PushSummary {
  configured: boolean
  keyId: string
  teamId: string
  bundleId: string
  sandbox: boolean
  hasKey: boolean
}

const KEY_HEAD = '-----BEGIN PRIVATE KEY-----'

export const pushInputSchema = z.object({
  keyId: z.string().trim().max(20).default('')
    .refine(value => !value || /^[A-Z0-9]{10}$/.test(value), 'A key ID is ten letters and digits, as Apple shows it.'),
  teamId: z.string().trim().max(20).default('')
    .refine(value => !value || /^[A-Z0-9]{10}$/.test(value), 'A team ID is ten letters and digits, as Apple shows it.'),
  bundleId: z.string().trim().max(200).default('')
    .refine(value => !value || /^[A-Za-z0-9.-]+$/.test(value), 'A bundle identifier looks like com.example.yardlink'),
  /** Left empty to keep the key already saved. */
  signingKey: z.string().max(4000).default(''),
  sandbox: z.coerce.boolean().default(false),
})
export type PushInput = z.infer<typeof pushInputSchema>

function text(value: unknown): string {
  return typeof value === 'string' ? value.trim() : ''
}

function configFromSettings(settings: Record<string, unknown> | null | undefined): PushConfig | null {
  const raw = settings?.push
  if (!raw || typeof raw !== 'object') return null
  const row = raw as Record<string, unknown>
  const keyId = text(row.keyId)
  const teamId = text(row.teamId)
  const bundleId = text(row.bundleId)
  const signingKey = openSecret(text(row.signingKey))
  if (!keyId || !teamId || !bundleId || !signingKey) return null
  return { keyId, teamId, bundleId, signingKey, sandbox: row.sandbox === true }
}

/** The saved push settings, or null when the employer has not set them up. */
export async function loadPushConfig(db: DbExecutor): Promise<PushConfig | null> {
  const company = await loadPrimaryCompany(db)
  return configFromSettings(company?.settings)
}

export function summarizePush(config: PushConfig | null): PushSummary {
  return {
    configured: Boolean(config),
    keyId: config?.keyId ?? '',
    teamId: config?.teamId ?? '',
    bundleId: config?.bundleId ?? '',
    sandbox: config?.sandbox ?? false,
    hasKey: Boolean(config?.signingKey),
  }
}

/** Fill the gaps in what was typed: an empty key keeps the saved one. */
export function resolvePushInput(input: PushInput, saved: PushConfig | null): PushConfig | null {
  const signingKey = input.signingKey.trim() || (saved?.signingKey ?? '')
  if (!input.keyId && !input.teamId && !input.bundleId && !signingKey) return null
  if (!input.keyId || !input.teamId || !input.bundleId) {
    throw createError({ statusCode: 422, statusMessage: 'Enter the key ID, the team ID and the app\'s bundle identifier.' })
  }
  if (!signingKey) {
    throw createError({ statusCode: 422, statusMessage: 'Paste the .p8 signing key Apple gave you.' })
  }
  if (!signingKey.includes(KEY_HEAD)) {
    throw createError({ statusCode: 422, statusMessage: 'That does not look like a .p8 key. Paste the whole file, BEGIN and END lines included.' })
  }
  return {
    keyId: input.keyId,
    teamId: input.teamId,
    bundleId: input.bundleId,
    signingKey,
    sandbox: input.sandbox,
  }
}

/** Pack for `companies.settings.push`. */
function sealedPush(config: PushConfig): Record<string, unknown> {
  return {
    keyId: config.keyId,
    teamId: config.teamId,
    bundleId: config.bundleId,
    signingKey: sealSecret(config.signingKey),
    sandbox: config.sandbox,
  }
}

/** Save push settings, or pass null to turn push off. */
export async function savePushConfig(db: DbExecutor, companyId: string, config: PushConfig | null): Promise<void> {
  const [row] = await db.select({ settings: companies.settings }).from(companies).where(eq(companies.id, companyId)).limit(1)
  const next: Record<string, unknown> = { ...(row?.settings ?? {}) }
  if (config) next.push = sealedPush(config)
  else delete next.push
  await db.update(companies).set({ settings: next, updatedAt: new Date() }).where(eq(companies.id, companyId))
}
