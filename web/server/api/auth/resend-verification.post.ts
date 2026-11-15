import { and, eq, sql } from 'drizzle-orm'
import { z } from 'zod'
import { companyMemberships, users } from '../../database/schema'
import { isWithinResendCooldown } from '../../services/email-verification'
import { sendWelcomeEmail } from '../../services/emails'
import { mailEnabled } from '../../services/mail'

const schema = z.object({
  email: z.string().trim().email('Enter a valid email address.').max(200),
})

/**
 * Sends the welcome email again.
 *
 * Always reports the same thing: saying whether an address is registered, or
 * already confirmed, would let anyone test which addresses have accounts.
 */
export default defineEventHandler(async (event) => {
  const body = await readValidatedJson(event, schema)
  const db = useDb()
  const generic = { ok: true, message: 'If that address is waiting to be confirmed, a new email is on its way.' }

  if (!(await mailEnabled(db))) return generic

  const [user] = await db
    .select()
    .from(users)
    .where(sql`lower(${users.email}) = lower(${body.email})`)
    .limit(1)

  if (!user || user.emailVerifiedAt || user.disabledAt) return generic
  if (await isWithinResendCooldown(db, user.id)) return generic

  const [pending] = await db
    .select({ id: companyMemberships.id })
    .from(companyMemberships)
    .where(and(eq(companyMemberships.userId, user.id), eq(companyMemberships.status, 'PENDING')))
    .limit(1)

  try {
    await sendWelcomeEmail(db, {
      user,
      origin: getRequestURL(event).origin,
      approvalRequired: Boolean(pending),
    })
  }
  catch (error) {
    console.warn('[resend-verification] delivery failed', error)
  }
  return generic
})
