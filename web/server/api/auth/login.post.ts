import { and, eq, sql } from 'drizzle-orm'
import { z } from 'zod'
import { parseUnlockedFeatures } from '#shared/utils/feature-codes'
import { roleHomePath } from '#shared/utils/domain'
import { companies, companyMemberships, drivers, users } from '../../database/schema'
import { mailEnabled } from '../../services/mail'
import { accountLockedError } from '../../utils/account-lock'

const schema = z.object({
  email: z.string().trim().email('Enter a valid email address.'),
  password: z.string().min(1, 'Enter your password.'),
})

/** Generic failure message — never reveals whether the email exists. */
const INVALID = 'Email or password is incorrect.'

/**
 * Session sign-in.
 *
 * Dispatchers (ADMIN) land on the map board; drivers land on the trip home.
 */
export default defineEventHandler(async (event) => {
  const body = await readValidatedJson(event, schema)
  const db = useDb()

  const [user] = await db
    .select()
    .from(users)
    .where(sql`lower(${users.email}) = lower(${body.email})`)
    .limit(1)

  if (!user) {
    throw createError({ statusCode: 401, statusMessage: INVALID })
  }

  const valid = await verifyPassword(user.passwordHash, body.password)
  if (!valid) {
    throw createError({ statusCode: 401, statusMessage: INVALID })
  }

  if (user.disabledAt) {
    throw accountLockedError()
  }

  // Reached only after the password succeeds, so it cannot be used to probe
  // which addresses are registered.
  if (!user.emailVerifiedAt) {
    if (await mailEnabled(db)) {
      throw createError({
        statusCode: 403,
        statusMessage: 'Confirm your email address first. Open the welcome email we sent you and tap Confirm My Email.',
        data: { emailUnverified: true },
      })
    }
    // Email was turned off after this person signed up: nothing can confirm
    // the address any more, so it is accepted.
    await db.update(users).set({ emailVerifiedAt: new Date() }).where(eq(users.id, user.id))
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
    .where(and(eq(companyMemberships.userId, user.id), eq(companyMemberships.status, 'ACTIVE')))
    .limit(1)

  if (!membership) {
    // Reached only after the password succeeds, so this cannot be used to probe
    // which addresses are registered.
    const [waiting] = await db
      .select({ id: companyMemberships.id })
      .from(companyMemberships)
      .where(and(eq(companyMemberships.userId, user.id), eq(companyMemberships.status, 'PENDING')))
      .limit(1)
    if (waiting) {
      throw createError({
        statusCode: 403,
        statusMessage: 'Your account is waiting for a dispatcher to approve it. Ask your dispatcher, then sign in again.',
        data: { approvalPending: true },
      })
    }
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

  await setUserSession(event, {
    user: {
      userId: user.id,
      email: user.email,
      firstName: user.firstName,
      lastName: user.lastName,
      fullName: `${user.firstName} ${user.lastName}`,
      role: membership.role,
      companyId: membership.companyId,
      companyName: membership.companyName,
      driverId,
    },
    secure: { membershipId: membership.id },
    loggedInAt: new Date().toISOString(),
    unlockedFeatures: parseUnlockedFeatures(user.unlockedFeatures),
  })

  await db.update(users).set({ lastLoginAt: new Date() }).where(eq(users.id, user.id))

  return {
    ok: true,
    role: membership.role,
    redirectTo: roleHomePath(membership.role),
  }
})
