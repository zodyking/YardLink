import { sql } from 'drizzle-orm'
import { z } from 'zod'
import { isBlankOrValidPhone, toE164 } from '#shared/utils/phone'
import { companies, companyMemberships, users } from '../../database/schema'
import { verifySmtp } from '../../services/mail'
import { generateInviteCode, loadPrimaryCompany } from '../../utils/company'
import { cleanPublicUrl, loadCompanySettings } from '../../utils/settings'
import { needsSetup } from '../../utils/setup'
import { startUserSession } from '../../utils/sign-in'
import { resolveSmtpInput, saveSmtpConfig, smtpInputSchema } from '../../utils/smtp-settings'

function isTimezone(value: string): boolean {
  try {
    new Intl.DateTimeFormat('en-US', { timeZone: value })
    return true
  }
  catch {
    return false
  }
}

const schema = z.object({
  company: z.object({
    name: z.string().trim().min(1, 'Enter the company name.').max(120),
    legalName: z.string().trim().max(160).optional().default(''),
    usdotNumber: z.string().trim().max(20).optional().default(''),
    timezone: z.string().trim().min(1).max(60).refine(isTimezone, 'Choose a timezone.'),
  }),
  admin: z.object({
    firstName: z.string().trim().min(1, 'First name is required.').max(80),
    lastName: z.string().trim().min(1, 'Last name is required.').max(80),
    email: z.string().trim().email('Enter a valid email address.').max(200),
    mobileNumber: z.string().trim().max(30).optional().default('').refine(isBlankOrValidPhone, 'Enter a 10-digit mobile number.'),
    password: z.string().min(10, 'Use at least 10 characters.').max(200),
  }),
  publicUrl: z.string().trim().max(300).optional().default(''),
  /** Outgoing email. Left out when the person skips that step. */
  email: smtpInputSchema.optional(),
})

/**
 * First-run setup. Creates the company and its first dispatcher, saves the
 * email settings if any were entered, then signs that person in. Only works
 * while the install has no dispatcher account — afterwards it answers 409 and
 * Settings is the place to make changes.
 *
 * The database was chosen one step earlier (`/api/setup/database`), so
 * everything here is written to the database the employer picked.
 */
export default defineEventHandler(async (event) => {
  const body = await readValidatedJson(event, schema)
  const db = useDb()

  if (!(await needsSetup(db))) {
    throw createError({ statusCode: 409, statusMessage: 'Yard Link is already set up. Sign in to change settings.' })
  }

  const publicUrl = cleanPublicUrl(body.publicUrl) || cleanPublicUrl(getRequestURL(event).origin)

  // Settings that cannot reach the mail server are refused here, before
  // anything is created, so the wizard can send the person back to that step.
  const smtp = body.email ? resolveSmtpInput(body.email, null, body.company.name) : null
  if (smtp) {
    const check = await verifySmtp(smtp)
    if (!check.ok) {
      throw createError({
        statusCode: 422,
        statusMessage: `The email settings did not work: ${check.message}`,
        data: { step: 'email' },
      })
    }
  }
  const passwordHash = await hashPassword(body.admin.password)

  const result = await db.transaction(async (tx) => {
    const existingCompany = await loadPrimaryCompany(tx)
    const companyValues = {
      name: body.company.name,
      legalName: body.company.legalName || null,
      usdotNumber: body.company.usdotNumber || null,
      timezone: body.company.timezone,
      updatedAt: new Date(),
    }

    const [company] = existingCompany
      ? await tx
          .update(companies)
          .set({ ...companyValues, settings: { ...(existingCompany.settings ?? {}), publicUrl } })
          .where(sql`${companies.id} = ${existingCompany.id}`)
          .returning()
      : await tx
          .insert(companies)
          .values({ ...companyValues, inviteCode: generateInviteCode(), settings: { publicUrl, approveNewAccounts: true } })
          .returning()

    if (!company) {
      throw createError({ statusCode: 500, statusMessage: 'Could not save the company.' })
    }

    const [taken] = await tx
      .select({ id: users.id })
      .from(users)
      .where(sql`lower(${users.email}) = lower(${body.admin.email})`)
      .limit(1)
    if (taken) {
      throw createError({ statusCode: 409, statusMessage: 'An account already exists for that email address.' })
    }

    const [user] = await tx
      .insert(users)
      .values({
        email: body.admin.email.toLowerCase(),
        passwordHash,
        firstName: body.admin.firstName,
        lastName: body.admin.lastName,
        mobileNumber: body.admin.mobileNumber ? toE164(body.admin.mobileNumber) : null,
        emailVerifiedAt: new Date(),
      })
      .returning()
    if (!user) {
      throw createError({ statusCode: 500, statusMessage: 'Could not create the account.' })
    }

    const [membership] = await tx
      .insert(companyMemberships)
      .values({ companyId: company.id, userId: user.id, role: 'ADMIN', status: 'ACTIVE' })
      .returning()

    if (smtp) await saveSmtpConfig(tx, company.id, smtp)

    return { company, user, membership: membership! }
  })

  await loadCompanySettings(db, { fresh: true })
  await startUserSession(event, {
    user: result.user,
    membership: {
      id: result.membership.id,
      role: 'ADMIN',
      companyId: result.company.id,
      companyName: result.company.name,
    },
    driverId: null,
  })

  return { ok: true, redirectTo: '/admin/settings?welcome=1' }
})
