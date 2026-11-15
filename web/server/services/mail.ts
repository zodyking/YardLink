import { randomUUID } from 'node:crypto'
import nodemailer from 'nodemailer'
import type { Transporter } from 'nodemailer'
import { formatSmtpFromHeader, smtpFromDomain } from '#shared/utils/smtp-from'
import type { DbExecutor } from '../utils/db'
import { loadSmtpConfig } from '../utils/smtp-settings'
import type { SmtpConfig } from '../utils/smtp-settings'

/**
 * Outgoing email.
 *
 * Email is optional. When the employer has not set it up, `sendMail` answers
 * false and callers carry on: everything still reaches people inside Yard
 * Link. Deliverability belongs to the mailbox the employer points this at.
 */
export interface MailMessage {
  to: string
  subject: string
  text: string
  html: string
}

let cachedKey = ''
let cachedTransport: Transporter | undefined

function transportFor(config: SmtpConfig): Transporter {
  const key = JSON.stringify([config.host, config.port, config.user, config.password])
  if (cachedTransport && cachedKey === key) return cachedTransport

  // Implicit TLS is a property of the port: only 465 speaks TLS from the
  // first byte. Every other port upgrades with STARTTLS.
  const secure = config.port === 465
  cachedTransport = nodemailer.createTransport({
    host: config.host,
    port: config.port,
    secure,
    auth: config.user ? { user: config.user, pass: config.password } : undefined,
    // Never hand a password to a server that will not encrypt the connection.
    requireTLS: !secure && Boolean(config.user),
    // A blocked outbound port must fail quickly, not hang the request.
    connectionTimeout: 10_000,
    greetingTimeout: 10_000,
    socketTimeout: 30_000,
  })
  cachedKey = key
  return cachedTransport
}

/** Mail servers answer with a code and a sentence; without them an error is useless. */
function describeSmtpError(error: unknown): string {
  if (!(error instanceof Error)) return String(error)
  const smtp = error as Error & { responseCode?: number, response?: string, code?: string }
  if (smtp.code === 'EAUTH') return 'The mail server rejected the user name or password.'
  if (smtp.code === 'EDNS' || smtp.code === 'ENOTFOUND') return 'The mail server address could not be found.'
  if (smtp.code === 'ETIMEDOUT' || smtp.code === 'ECONNECTION' || smtp.code === 'ESOCKET') {
    return `The mail server did not answer on that port (${smtp.message}).`
  }
  const parts = [smtp.message]
  if (smtp.response && !smtp.message.includes(smtp.response)) parts.push(smtp.response)
  return parts.join(' — ')
}

/** Sign in to the mail server without sending anything. */
export async function verifySmtp(config: SmtpConfig): Promise<{ ok: boolean, message: string }> {
  try {
    await transportFor(config).verify()
    return { ok: true, message: `Connected to ${config.host} on port ${config.port}.` }
  }
  catch (error) {
    return { ok: false, message: describeSmtpError(error) }
  }
}

/** Send through specific settings. Throws with the mail server's own reason. */
export async function sendMailWith(config: SmtpConfig, message: MailMessage): Promise<void> {
  const from = formatSmtpFromHeader(config.fromName, config.fromEmail)
  try {
    await transportFor(config).sendMail({
      from,
      to: message.to,
      subject: message.subject.trim(),
      text: message.text,
      html: message.html,
      // A domain-matched Message-ID helps transactional mail stay out of spam.
      messageId: `<yardlink.${randomUUID()}@${smtpFromDomain(from) ?? 'localhost'}>`,
    })
  }
  catch (error) {
    throw new Error(describeSmtpError(error), { cause: error })
  }
}

export async function mailEnabled(db: DbExecutor): Promise<boolean> {
  return Boolean(await loadSmtpConfig(db))
}

/**
 * Send with the employer's saved settings. Answers false when email is not
 * set up; throws when it is set up and the mail server refuses.
 */
export async function sendMail(db: DbExecutor, message: MailMessage): Promise<boolean> {
  const config = await loadSmtpConfig(db)
  if (!config) return false
  await sendMailWith(config, message)
  return true
}

/**
 * For notices that must never fail the action that caused them: the work is
 * already saved and already visible inside Yard Link.
 */
export async function sendMailQuietly(db: DbExecutor, message: MailMessage, label: string): Promise<void> {
  try {
    await sendMail(db, message)
  }
  catch (error) {
    console.warn(`[mail] ${label} to ${message.to} was not delivered:`, error instanceof Error ? error.message : error)
  }
}
