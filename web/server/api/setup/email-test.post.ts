import { z } from 'zod'
import { sendTestEmail } from '../../services/emails'
import { needsSetup } from '../../utils/setup'
import { resolveSmtpInput, smtpInputSchema } from '../../utils/smtp-settings'

const schema = z.object({
  settings: smtpInputSchema,
  to: z.string().trim().email('Enter a valid email address.').max(200),
  companyName: z.string().trim().max(120).default(''),
})

/**
 * First-run setup: try the email settings before they are saved. Only works
 * while the install has no dispatcher account; afterwards Settings has its
 * own test button behind sign-in.
 */
export default defineEventHandler(async (event) => {
  const body = await readValidatedJson(event, schema)
  if (!(await needsSetup(useDb()))) {
    throw createError({ statusCode: 409, statusMessage: 'Yard Link is already set up. Sign in to change settings.' })
  }

  const company = body.companyName || 'Yard Link'
  const config = resolveSmtpInput(body.settings, null, company)
  try {
    await sendTestEmail(config, body.to, company)
  }
  catch (error) {
    throw createError({ statusCode: 422, statusMessage: error instanceof Error ? error.message : 'The test email could not be sent.' })
  }
  return { ok: true, message: `Test email sent to ${body.to}.` }
})
