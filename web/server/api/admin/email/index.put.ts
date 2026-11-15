import { loadPrimaryCompany } from '../../../utils/company'
import { requireAdmin } from '../../../utils/session'
import { loadSmtpConfig, resolveSmtpInput, saveSmtpConfig, smtpInputSchema, summarizeSmtp } from '../../../utils/smtp-settings'
import { verifySmtp } from '../../../services/mail'

/**
 * Saves the outgoing email settings. They are checked against the mail server
 * first, so settings that cannot send are never saved.
 */
export default defineEventHandler(async (event) => {
  const auth = await requireAdmin(event)
  const body = await readValidatedJson(event, smtpInputSchema)
  const db = useDb()

  const company = await loadPrimaryCompany(db)
  const config = resolveSmtpInput(body, await loadSmtpConfig(db), company?.name ?? auth.companyName)

  const check = await verifySmtp(config)
  if (!check.ok) {
    throw createError({ statusCode: 422, statusMessage: check.message })
  }

  await saveSmtpConfig(db, auth.companyId, config)
  return { ok: true, email: summarizeSmtp(config), message: check.message }
})
