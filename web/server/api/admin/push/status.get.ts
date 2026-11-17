import { desc, eq } from 'drizzle-orm'
import { deviceTokens, users } from '../../../database/schema'
import { requireAdmin } from '../../../utils/session'
import { recentPushes } from '../../../utils/push-log'

/** Which phones are signed in for notices, and what happened to the last few. */
export default defineEventHandler(async (event) => {
  const auth = await requireAdmin(event)
  const phones = await useDb()
    .select({
      firstName: users.firstName,
      lastName: users.lastName,
      sandbox: deviceTokens.sandbox,
      appVersion: deviceTokens.appVersion,
      lastSeenAt: deviceTokens.lastSeenAt,
    })
    .from(deviceTokens)
    .innerJoin(users, eq(users.id, deviceTokens.userId))
    .where(eq(deviceTokens.companyId, auth.companyId))
    .orderBy(desc(deviceTokens.lastSeenAt))
    .limit(50)

  return {
    phones: phones.map(phone => ({
      name: `${phone.firstName} ${phone.lastName}`.trim(),
      service: phone.sandbox ? 'Development' : 'Production',
      appVersion: phone.appVersion,
      lastSeenAt: phone.lastSeenAt,
    })),
    recent: recentPushes(),
  }
})
