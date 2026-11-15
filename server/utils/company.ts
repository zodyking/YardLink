import { createHash, randomInt, timingSafeEqual } from 'node:crypto'
import { asc } from 'drizzle-orm'
import { companies } from '../database/schema'
import type { DbExecutor } from './db'

/**
 * Company identity for a single-employer deployment.
 *
 * Everything an employer configures lives in the database and is edited in
 * the web app: the first-run setup wizard creates the company, and
 * Settings changes it afterwards. Nothing here reads environment variables.
 */

/** Uppercase and strip separators so `yl-7k2p` and `YL7K2P` both match. */
export function normalizeInviteCode(code: unknown): string {
  if (code === null || code === undefined) return ''
  return String(code).trim().toUpperCase().replace(/[\s-]/g, '')
}

/**
 * Compares codes without leaking length or content through timing. Digesting
 * first keeps both operands the same length, which `timingSafeEqual` requires.
 */
export function inviteCodeMatches(submitted: unknown, expected: unknown): boolean {
  if (!expected) return false
  const a = createHash('sha256').update(normalizeInviteCode(submitted)).digest()
  const b = createHash('sha256').update(normalizeInviteCode(expected)).digest()
  return timingSafeEqual(a, b)
}

/** No 0/O or 1/I, so the code survives being read out over a radio. */
const CODE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'

/** Stored without separators, e.g. `YL7K2PQ9XM`. */
export function generateInviteCode(): string {
  let code = 'YL'
  for (let i = 0; i < 8; i += 1) code += CODE_ALPHABET[randomInt(CODE_ALPHABET.length)]
  return code
}

/** `YL7K2PQ9XM` → `YL-7K2P-Q9XM` for display. */
export function formatInviteCode(code: string): string {
  const clean = normalizeInviteCode(code)
  if (clean.length !== 10) return clean
  return `${clean.slice(0, 2)}-${clean.slice(2, 6)}-${clean.slice(6)}`
}

/** The deployment's company, or null before first-run setup. */
export async function loadPrimaryCompany(db: DbExecutor) {
  const [existing] = await db
    .select()
    .from(companies)
    .orderBy(asc(companies.createdAt))
    .limit(1)
  return existing ?? null
}

export async function ensurePrimaryCompany(db: DbExecutor) {
  const company = await loadPrimaryCompany(db)
  if (!company) {
    throw createError({
      statusCode: 503,
      statusMessage: 'Yard Link has not been set up yet. Open the web app to finish setup.',
    })
  }
  return company
}
