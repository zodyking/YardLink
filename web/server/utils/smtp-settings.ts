import { eq } from 'drizzle-orm'
import { z } from 'zod'
import { companies } from '../database/schema'
import { loadPrimaryCompany } from './company'
import type { DbExecutor } from './db'
import { openSecret, sealSecret } from './secret-box'

/**
 * Outgoing email (SMTP), entered in the setup wizard or under Settings and
 * kept with the company's other settings. The password is stored sealed and
 * is never sent back to a browser.
 */
export interface SmtpConfig {
  host: string
  port: number
  user: string
  password: string
  fromName: string
  fromEmail: string
}

/** What the web app is allowed to see. */
export interface SmtpSummary {
  configured: boolean
  host: string
  port: number
  user: string
  fromName: string
  fromEmail: string
  hasPassword: boolean
}

const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/

/** One shape for the wizard, Settings and the test button. */
export const smtpInputSchema = z.object({
  host: z.string().trim().min(1, 'Enter the mail server address.').max(200)
    .regex(/^[^\s/:]+$/, 'Enter only the server name, like smtp.example.com'),
  port: z.coerce.number().int().min(1, 'Enter a port between 1 and 65535.').max(65535, 'Enter a port between 1 and 65535.').default(587),
  user: z.string().trim().max(200).default(''),
  /** Left empty to keep the password already saved. */
  password: z.string().max(500).default(''),
  fromName: z.string().trim().max(120).default(''),
  fromEmail: z.string().trim().max(200).default('')
    .refine(value => !value || EMAIL_PATTERN.test(value), 'Enter a valid From address.'),
})
export type SmtpInput = z.infer<typeof smtpInputSchema>

function text(value: unknown): string {
  return typeof value === 'string' ? value.trim() : ''
}

function configFromSettings(settings: Record<string, unknown> | null | undefined): SmtpConfig | null {
  const raw = settings?.smtp
  if (!raw || typeof raw !== 'object') return null
  const row = raw as Record<string, unknown>
  const host = text(row.host)
  const fromEmail = text(row.fromEmail)
  if (!host || !fromEmail) return null
  return {
    host,
    port: Number(row.port) || 587,
    user: text(row.user),
    password: openSecret(text(row.password)),
    fromName: text(row.fromName),
    fromEmail,
  }
}

/** The saved mail settings, or null when the employer has not set up email. */
export async function loadSmtpConfig(db: DbExecutor): Promise<SmtpConfig | null> {
  const company = await loadPrimaryCompany(db)
  return configFromSettings(company?.settings)
}

export function summarizeSmtp(config: SmtpConfig | null): SmtpSummary {
  return {
    configured: Boolean(config),
    host: config?.host ?? '',
    port: config?.port ?? 587,
    user: config?.user ?? '',
    fromName: config?.fromName ?? '',
    fromEmail: config?.fromEmail ?? '',
    hasPassword: Boolean(config?.password),
  }
}

/**
 * Fill the gaps in what was typed: an empty password keeps the saved one, and
 * an empty From address falls back to the sign-in name when that is a mailbox,
 * which is the only From most providers accept anyway.
 */
export function resolveSmtpInput(input: SmtpInput, saved: SmtpConfig | null, companyName: string): SmtpConfig {
  const fromEmail = input.fromEmail || (EMAIL_PATTERN.test(input.user) ? input.user : '')
  if (!fromEmail) {
    throw createError({ statusCode: 422, statusMessage: 'Enter the From address that emails are sent from.' })
  }
  return {
    host: input.host,
    port: input.port,
    user: input.user,
    password: input.password || (saved?.password ?? ''),
    fromName: input.fromName || companyName,
    fromEmail,
  }
}

/** Pack for `companies.settings.smtp`. */
function sealedSmtp(config: SmtpConfig): Record<string, unknown> {
  return {
    host: config.host,
    port: config.port,
    user: config.user,
    password: sealSecret(config.password),
    fromName: config.fromName,
    fromEmail: config.fromEmail,
  }
}

/** Save mail settings, or pass null to turn email off. */
export async function saveSmtpConfig(db: DbExecutor, companyId: string, config: SmtpConfig | null): Promise<void> {
  const [row] = await db.select({ settings: companies.settings }).from(companies).where(eq(companies.id, companyId)).limit(1)
  const next: Record<string, unknown> = { ...(row?.settings ?? {}) }
  if (config) next.smtp = sealedSmtp(config)
  else delete next.smtp
  await db.update(companies).set({ settings: next, updatedAt: new Date() }).where(eq(companies.id, companyId))
}
