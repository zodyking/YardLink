import { and, eq } from 'drizzle-orm'
import { z } from 'zod'
import { companyMemberships, drivers, users } from '../../../../database/schema'
import { sendApprovedEmail } from '../../../../services/emails'
import { postSystemNotice } from '../../../../services/messages'
import { requireAdmin } from '../../../../utils/session'

const schema = z.object({ approve: z.boolean() })

/**
 * Approve or decline someone who signed up with the join code. A dispatcher
 * vouches for the person; when email is set up they are told the result.
 */
export default defineEventHandler(async (event) => {
  const auth = await requireAdmin(event)
  const userId = getRouterParam(event, 'userId')
  if (!userId) throw createError({ statusCode: 400, statusMessage: 'Person is required.' })
  const body = await readValidatedJson(event, schema)
  const db = useDb()

  const [membership] = await db
    .select()
    .from(companyMemberships)
    .where(and(eq(companyMemberships.userId, userId), eq(companyMemberships.companyId, auth.companyId)))
    .limit(1)
  if (!membership) throw createError({ statusCode: 404, statusMessage: 'Person not found.' })
  if (membership.status !== 'PENDING') {
    throw createError({ statusCode: 409, statusMessage: 'This account has already been reviewed.' })
  }

  const now = new Date()
  if (body.approve) {
    await db.transaction(async (tx) => {
      await tx
        .update(companyMemberships)
        .set({ status: 'ACTIVE', invitedByUserId: auth.userId, updatedAt: now })
        .where(eq(companyMemberships.id, membership.id))
      if (membership.role === 'DRIVER') {
        await tx
          .insert(drivers)
          .values({ companyId: auth.companyId, userId, status: 'AVAILABLE' })
          .onConflictDoNothing()
      }
    })
    if (membership.role === 'DRIVER') {
      await postSystemNotice(db, {
        companyId: auth.companyId,
        driverUserId: userId,
        kind: 'ACCOUNT',
        body: `${auth.fullName} approved your account. Message dispatch here any time.`,
      })
    }
    const [person] = await db
      .select({ email: users.email, firstName: users.firstName })
      .from(users)
      .where(eq(users.id, userId))
      .limit(1)
    if (person) await sendApprovedEmail(db, person, auth.fullName)
    return { ok: true, status: 'ACTIVE' }
  }

  // Declined: the sign-up is removed so the address can be used again.
  await db.transaction(async (tx) => {
    await tx.delete(drivers).where(and(eq(drivers.userId, userId), eq(drivers.companyId, auth.companyId)))
    await tx.delete(companyMemberships).where(eq(companyMemberships.id, membership.id))
    await tx.delete(users).where(eq(users.id, userId))
  })
  return { ok: true, status: 'DECLINED' }
})
