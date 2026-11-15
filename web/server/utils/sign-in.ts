import type { H3Event } from 'h3'
import { parseUnlockedFeatures } from '#shared/utils/feature-codes'
import type { Role } from '#shared/utils/domain'

/** Start a session. One shape for every way of signing in. */
export async function startUserSession(event: H3Event, input: {
  user: { id: string, email: string, firstName: string, lastName: string, unlockedFeatures?: unknown }
  membership: { id: string, role: Role, companyId: string, companyName: string }
  driverId: string | null
}) {
  await setUserSession(event, {
    user: {
      userId: input.user.id,
      email: input.user.email,
      firstName: input.user.firstName,
      lastName: input.user.lastName,
      fullName: `${input.user.firstName} ${input.user.lastName}`,
      role: input.membership.role,
      companyId: input.membership.companyId,
      companyName: input.membership.companyName,
      driverId: input.driverId,
    },
    secure: { membershipId: input.membership.id },
    loggedInAt: new Date().toISOString(),
    unlockedFeatures: parseUnlockedFeatures(input.user.unlockedFeatures),
  })
}
