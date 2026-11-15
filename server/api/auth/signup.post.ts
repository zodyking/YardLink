import { sql } from 'drizzle-orm'
import { z } from 'zod'
import { isValidPhone, toE164 } from '#shared/utils/phone'
import { membershipRoleForSignup, SIGNUP_ROLES } from '#shared/utils/domain'
import { companyMemberships, drivers, users } from '../../database/schema'
import { postSystemNotice } from '../../services/messages'
import { ensurePrimaryCompany, inviteCodeMatches } from '../../utils/company'
import { loadCompanySettings } from '../../utils/settings'

const schema = z.object({
  firstName: z.string().trim().min(1, 'First name is required.').max(80),
  lastName: z.string().trim().min(1, 'Last name is required.').max(80),
  email: z.string().trim().email('Enter a valid email address.').max(200),
  mobileNumber: z.string()
    .trim()
    .max(30)
    .refine(isValidPhone, 'Enter a 10-digit mobile number.'),
  password: z.string().min(10, 'Use at least 10 characters.').max(200),
  inviteCode: z.string().trim().min(1, 'A company invite code is required.').max(60),
  role: z.enum(SIGNUP_ROLES).default('DRIVER'),
})

/**
 * Public self-registration (spec 4). The person needs the company join code;
 * with approval on (the default) a dispatcher then lets them in.
 *
 * Drivers get a DRIVER membership plus a drivers row. Dispatchers get an ADMIN
 * membership and no drivers row — they use the map board, not the trip home.
 */
export default defineEventHandler(async (event) => {
  const body = await readValidatedJson(event, schema)
  const db = useDb()

  // The join code lives on the company record; dispatchers can replace it in
  // Settings at any time without touching the server.
  const company = await ensurePrimaryCompany(db)

  if (!inviteCodeMatches(body.inviteCode, company.inviteCode)) {
    throw createError({ statusCode: 403, statusMessage: 'That join code is not valid.' })
  }

  const settings = await loadCompanySettings(db, { fresh: true })
  const membershipStatus = settings.approveNewAccounts ? 'PENDING' as const : 'ACTIVE' as const

  const [existing] = await db
    .select({ id: users.id })
    .from(users)
    .where(sql`lower(${users.email}) = lower(${body.email})`)
    .limit(1)

  if (existing) {
    throw createError({ statusCode: 409, statusMessage: 'An account already exists for that email address.' })
  }

  const passwordHash = await hashPassword(body.password)
  const membershipRole = membershipRoleForSignup(body.role)

  const result = await db.transaction(async (tx) => {
    const [user] = await tx
      .insert(users)
      .values({
        email: body.email.toLowerCase(),
        passwordHash,
        firstName: body.firstName,
        lastName: body.lastName,
        // Stored canonically so the same number is never duplicated by format.
        mobileNumber: toE164(body.mobileNumber),
        // No emailed link: a dispatcher approves the account instead.
        emailVerifiedAt: new Date(),
      })
      .returning()

    if (!user) {
      throw createError({ statusCode: 500, statusMessage: 'Could not create the account.' })
    }

    const [membership] = await tx
      .insert(companyMemberships)
      .values({ companyId: company.id, userId: user.id, role: membershipRole, status: membershipStatus })
      .returning()

    // The driver profile is created on approval, so someone still waiting
    // never shows up on the roster or in the dispatch desk.
    if (membershipRole === 'DRIVER' && membershipStatus === 'ACTIVE') {
      await tx
        .insert(drivers)
        .values({ companyId: company.id, userId: user.id, status: 'AVAILABLE' })
    }

    return { user, membership: membership! }
  })

  // Let whoever is on the desk know someone is waiting, right in Messages.
  if (membershipStatus === 'PENDING' && membershipRole === 'DRIVER') {
    await postSystemNotice(db, {
      companyId: company.id,
      driverUserId: result.user.id,
      kind: 'ACCOUNT',
      body: `${result.user.firstName} ${result.user.lastName} signed up as a driver and is waiting for approval. Review under Drivers.`,
    }).catch(error => console.warn('[signup] approval notice failed', error))
  }

  // No session yet when approval is on: the account is inert until reviewed.
  return {
    ok: true,
    approvalRequired: membershipStatus === 'PENDING',
    email: result.user.email,
  }
})
