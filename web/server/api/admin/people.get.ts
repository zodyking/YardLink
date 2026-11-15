import { eq, sql } from 'drizzle-orm'
import { companyMemberships, users } from '../../database/schema'
import { requireAdmin } from '../../utils/session'

/** Everyone with an account here: drivers, dispatchers, and people waiting for approval. */
export default defineEventHandler(async (event) => {
  const auth = await requireAdmin(event)
  const rows = await useDb()
    .select({
      userId: users.id,
      firstName: users.firstName,
      lastName: users.lastName,
      email: users.email,
      emailVerifiedAt: users.emailVerifiedAt,
      mobileNumber: users.mobileNumber,
      role: companyMemberships.role,
      status: companyMemberships.status,
      lockedAt: users.disabledAt,
      lastLoginAt: users.lastLoginAt,
      requestedAt: companyMemberships.createdAt,
    })
    .from(companyMemberships)
    .innerJoin(users, eq(users.id, companyMemberships.userId))
    .where(eq(companyMemberships.companyId, auth.companyId))
    .orderBy(sql`${companyMemberships.status} = 'PENDING' desc`, users.lastName, users.firstName)

  return {
    pending: rows.filter(row => row.status === 'PENDING'),
    people: rows.filter(row => row.status !== 'PENDING').map(row => ({ ...row, isYou: row.userId === auth.userId })),
  }
})
