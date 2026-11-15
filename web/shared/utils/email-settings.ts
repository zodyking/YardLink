/** The outgoing email form, as typed in the setup wizard and in Settings. */
export interface EmailSettingsForm {
  host: string
  port: number | string
  user: string
  password: string
  fromName: string
  fromEmail: string
}

const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/

export function emptyEmailSettings(): EmailSettingsForm {
  return { host: '', port: 587, user: '', password: '', fromName: '', fromEmail: '' }
}

/** Field → message for anything that would stop these settings from sending. */
export function checkEmailSettings(form: EmailSettingsForm): Record<string, string> {
  const errors: Record<string, string> = {}
  const host = form.host.trim()
  if (!host) errors.host = 'Enter the mail server address.'
  else if (/[\s/:]/.test(host)) errors.host = 'Enter only the server name, like smtp.example.com'

  const port = Number(form.port)
  if (!Number.isInteger(port) || port < 1 || port > 65535) errors.port = 'Enter a port between 1 and 65535.'

  const from = form.fromEmail.trim()
  if (from && !EMAIL_PATTERN.test(from)) errors.fromEmail = 'Enter a valid sender address.'
  else if (!from && !EMAIL_PATTERN.test(form.user.trim())) {
    errors.fromEmail = 'Enter the address emails are sent from.'
  }
  return errors
}
