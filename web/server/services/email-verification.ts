import { createHash, randomBytes } from 'node:crypto'
import { and, desc, eq, gt, isNull } from 'drizzle-orm'
import { emailVerificationTokens, users } from '../database/schema'
import type { DbExecutor } from '../utils/db'

/**
 * Email confirmation links for new accounts.
 *
 * The raw token goes into the link exactly once. Only its digest is stored,
 * so a copy of the database cannot be used to confirm someone else's address.
 */

export const VERIFICATION_HOURS = 24
/** Stops the resend button from being used to flood an inbox. */
const RESEND_COOLDOWN_SECONDS = 60

function hashToken(token: string): string {
  return createHash('sha256').update(token).digest('hex')
}

/**
 * Cancels any earlier links and issues a new one, so an old email stops
 * working as soon as the person asks for another.
 */
export async function issueEmailVerification(db: DbExecutor, userId: string, email: string): Promise<string> {
  const token = randomBytes(32).toString('base64url')

  await db
    .update(emailVerificationTokens)
    .set({ consumedAt: new Date() })
    .where(and(eq(emailVerificationTokens.userId, userId), isNull(emailVerificationTokens.consumedAt)))

  await db.insert(emailVerificationTokens).values({
    userId,
    tokenHash: hashToken(token),
    sentToEmail: email.toLowerCase(),
    expiresAt: new Date(Date.now() + VERIFICATION_HOURS * 3_600_000),
  })

  return token
}

/** True when the newest link for this person is younger than the cooldown. */
export async function isWithinResendCooldown(db: DbExecutor, userId: string): Promise<boolean> {
  const [latest] = await db
    .select({ createdAt: emailVerificationTokens.createdAt })
    .from(emailVerificationTokens)
    .where(eq(emailVerificationTokens.userId, userId))
    .orderBy(desc(emailVerificationTokens.createdAt))
    .limit(1)

  if (!latest) return false
  return Date.now() - latest.createdAt.getTime() < RESEND_COOLDOWN_SECONDS * 1000
}

/**
 * Uses a link and marks the address confirmed. Answers null for anything
 * invalid, expired or already used; callers must not tell those apart to a
 * visitor who is not signed in.
 */
export async function consumeEmailVerification(db: DbExecutor, token: string): Promise<string | null> {
  const candidate = token.trim()
  if (!candidate) return null

  const now = new Date()
  const [row] = await db
    .update(emailVerificationTokens)
    .set({ consumedAt: now })
    .where(and(
      eq(emailVerificationTokens.tokenHash, hashToken(candidate)),
      isNull(emailVerificationTokens.consumedAt),
      gt(emailVerificationTokens.expiresAt, now),
    ))
    .returning({ userId: emailVerificationTokens.userId })

  if (!row) return null

  const [user] = await db
    .update(users)
    .set({ emailVerifiedAt: now, updatedAt: now })
    .where(eq(users.id, row.userId))
    .returning({ id: users.id })

  return user?.id ?? null
}
