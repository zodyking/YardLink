import { emailTopicsForRole, parseEmailPrefs } from '#shared/utils/email-prefs'
import { mailEnabled } from '../../services/mail'
import { loadAccountUser, loadDriverEquipment } from '../../utils/account'
import { requireAuth } from '../../utils/session'

/**
 * Current account fields for Settings.
 *
 * Phone lives only in the user row, not the session cookie, so this is the
 * source of truth after a number change. Drivers also get CDL and truck VIN.
 * `notifications` says which topics this person can also get by email, which are on,
 * and whether the employer has set up email at all.
 */
export default defineEventHandler(async (event) => {
  const auth = await requireAuth(event)
  const user = await loadAccountUser(auth.userId)
  const driver = await loadDriverEquipment(auth.userId, auth.companyId, auth.driverId)

  return {
    firstName: user.firstName,
    lastName: user.lastName,
    email: user.email,
    mobileNumber: user.mobileNumber,
    companyName: auth.companyName,
    driver,
    notifications: {
      emailAvailable: await mailEnabled(useDb()),
      emailTopics: emailTopicsForRole(auth.role),
      emailPrefs: parseEmailPrefs(user.emailPrefs),
    },
  }
})
