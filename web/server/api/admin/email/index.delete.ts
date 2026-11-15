import { requireAdmin } from '../../../utils/session'
import { saveSmtpConfig, summarizeSmtp } from '../../../utils/smtp-settings'

/**
 * Turns email off. Nothing else stops working: people are told about work and
 * messages inside Yard Link, and new accounts no longer confirm an address.
 */
export default defineEventHandler(async (event) => {
  const auth = await requireAdmin(event)
  await saveSmtpConfig(useDb(), auth.companyId, null)
  return { ok: true, email: summarizeSmtp(null) }
})
