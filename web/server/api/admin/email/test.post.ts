import { z } from 'zod'
import { sendTestEmail } from '../../../services/emails'
import { loadPrimaryCompany } from '../../../utils/company'
import { requireAdmin } from '../../../utils/session'
import { loadSmtpConfig, resolveSmtpInput, smtpInputSchema } from '../../../utils/smtp-settings'

const schema = z.object({
  /** Settings as typed, to try them before saving. Omit to test what is saved. */
  settings: smtpInputSchema.optional(),
  /** Defaults to the signed-in dispatcher's own address. */
  to: z.string().trim().email('Enter a valid email address.').max(200).optional(),
})

/**
 * Sends a test email and reports the mail server's own answer, so the person
 * who can fix the settings sees exactly what was refused.
 */
export default defineEventHandler(async (event) => {
  const auth = await requireAdmin(event)
  const body = await readValidatedJson(event, schema)
  const db = useDb()

  const company = (await loadPrimaryCompany(db))?.name ?? auth.companyName
  const saved = await loadSmtpConfig(db)
  const config = body.settings ? resolveSmtpInput(body.settings, saved, company) : saved
  if (!config) {
    throw createError({ statusCode: 422, statusMessage: 'Enter the email settings first.' })
  }

  const to = body.to ?? auth.email
  try {
    await sendTestEmail(config, to, company)
  }
  catch (error) {
    throw createError({ statusCode: 422, statusMessage: error instanceof Error ? error.message : 'The test email could not be sent.' })
  }
  return { ok: true, message: `Test email sent to ${to}.` }
})
