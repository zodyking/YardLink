import { and, eq } from 'drizzle-orm'
import { z } from 'zod'
import { roleHomePath } from '#shared/utils/domain'
import { companies, companyMemberships, drivers, users } from '../../database/schema'
import { consumeEmailVerification } from '../../services/email-verification'
import { accountLockedError } from '../../utils/account-lock'
import { startUserSession } from '../../utils/sign-in'

const schema = z.object({
  token: z.string().trim().min(1, 'This link is missing its code.').max(400),
})

/**
 * Confirms an email address from the link in the welcome email.
 *
 * When the account is already active the person is signed in here: the link
 * proves they control the address, and it saves someone standing in a yard
 * from typing a password again. An account still waiting for a dispatcher is
 * confirmed and told to wait.
 */
export default defineEventHandler(async (event) => {
  const body = await readValidatedJson(event, schema)
  const db = useDb()

  const userId = await consumeEmailVerification(db, body.token)
  if (!userId) {
    throw createError({
      statusCode: 400,
      statusMessage: 'This link is not valid any more. Ask for a new email below.',
    })
  }

  const [user] = await db.select().from(users).where(eq(users.id, userId)).limit(1)
  if (!user) {
    throw createError({ statusCode: 403, statusMessage: 'This account is not active.' })
  }
  if (user.disabledAt) {
    throw accountLockedError()
  }

  const [membership] = await db
    .select({
      id: companyMemberships.id,
      role: companyMemberships.role,
      status: companyMemberships.status,
      companyId: companies.id,
      companyName: companies.name,
    })
    .from(companyMemberships)
    .innerJoin(companies, eq(companies.id, companyMemberships.companyId))
    .where(eq(companyMemberships.userId, user.id))
    .limit(1)

  if (!membership) {
    throw createError({ statusCode: 403, statusMessage: 'Your account is not active in any company.' })
  }
  if (membership.status === 'PENDING') {
    return { ok: true, approvalPending: true, redirectTo: null }
  }
  if (membership.status !== 'ACTIVE') {
    throw createError({ statusCode: 403, statusMessage: 'Your account is not active in any company.' })
  }

  let driverId: string | null = null
  if (membership.role === 'DRIVER') {
    const [driver] = await db
      .select({ id: drivers.id })
      .from(drivers)
      .where(and(eq(drivers.userId, user.id), eq(drivers.companyId, membership.companyId)))
      .limit(1)
    driverId = driver?.id ?? null
  }

  await startUserSession(event, { user, membership, driverId })
  await db.update(users).set({ lastLoginAt: new Date() }).where(eq(users.id, user.id))

  return { ok: true, approvalPending: false, redirectTo: roleHomePath(membership.role) }
})
