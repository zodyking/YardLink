import { and, eq, ne, sql } from 'drizzle-orm'
import { DISPATCH_TASK_KIND_LABELS } from '#shared/utils/domain'
import { displayContainerNumber } from '#shared/utils/dispatch-cards'
import type { EmailTopic } from '#shared/utils/email-prefs'
import { companyMemberships, messageThreads, users } from '../database/schema'
import { loadPrimaryCompany } from '../utils/company'
import type { DbExecutor } from '../utils/db'
import { loadCompanySettings } from '../utils/settings'
import type { SmtpConfig } from '../utils/smtp-settings'
import { renderEmail } from './email-layout'
import { VERIFICATION_HOURS, issueEmailVerification } from './email-verification'
import { sendMail, sendMailQuietly, sendMailWith } from './mail'
import type { DispatchTaskView } from './tasks'

/**
 * Every email Yard Link writes.
 *
 * Account emails (confirming an address, approval, a changed sign-in email)
 * always go out when the employer has set up email. Everything else is a copy
 * of something already shown inside Yard Link and is sent only to people who
 * turned that topic on in their own settings.
 */

interface Recipient {
  email: string
  firstName: string
}

async function companyName(db: DbExecutor): Promise<string> {
  return (await loadPrimaryCompany(db))?.name ?? 'Yard Link'
}

/** Address for links in email: the one the employer set, never a guess. */
async function linkTo(db: DbExecutor, path: string): Promise<string | null> {
  const base = (await loadCompanySettings(db)).publicUrl
  return base ? `${base}${path}` : null
}

/** `topic` is one of a fixed set of names, so it is written into the query as is. */
function wantsEmail(topic: EmailTopic) {
  return sql`${users.emailPrefs} ->> ${sql.raw(`'${topic}'`)} = 'true'`
}

function formatWorkDate(isoDate: string): string {
  const [year, month, day] = isoDate.split('-').map(Number)
  if (!year || !month || !day) return isoDate
  return new Intl.DateTimeFormat('en-US', {
    weekday: 'long',
    month: 'long',
    day: 'numeric',
    timeZone: 'UTC',
  }).format(new Date(Date.UTC(year, month - 1, day)))
}

/* ── Account ─────────────────────────────────────────────────────────── */

/**
 * Welcome a new person and ask them to confirm their address. Throws when
 * the mail server refuses, so sign-up can say the email did not go out.
 */
export async function sendWelcomeEmail(db: DbExecutor, input: {
  user: Recipient & { id: string }
  /** Origin of the request, used when the employer has not set an address. */
  origin: string
  approvalRequired: boolean
}): Promise<void> {
  const company = await companyName(db)
  const token = await issueEmailVerification(db, input.user.id, input.user.email)
  const base = (await loadCompanySettings(db)).publicUrl || input.origin.replace(/\/+$/, '')
  const link = `${base}/verify-email?token=${encodeURIComponent(token)}`

  const message = renderEmail({
    companyName: company,
    preview: `Confirm your email to finish joining ${company}.`,
    heading: `Welcome to ${company}, ${input.user.firstName}`,
    paragraphs: [
      `Your Yard Link account has been created. Yard Link is where you will see your trips and tasks, find containers and chassis, and message dispatch.`,
      'Confirm your email address to finish signing up.',
    ],
    button: { label: 'Confirm My Email', url: link },
    notes: [
      input.approvalRequired
        ? 'After you confirm, a dispatcher approves your account. You can sign in as soon as they do.'
        : 'After you confirm, you are signed in and ready to go.',
      `This link works for ${VERIFICATION_HOURS} hours. If you did not create this account, you can ignore this email.`,
    ],
  })

  await sendMail(db, { to: input.user.email, subject: `Welcome to ${company}: confirm your email`, ...message })
}

export async function sendApprovedEmail(db: DbExecutor, user: Recipient, approvedBy: string): Promise<void> {
  const company = await companyName(db)
  const link = await linkTo(db, '/login')
  const message = renderEmail({
    companyName: company,
    preview: 'Your account was approved. You can sign in now.',
    heading: `You're approved, ${user.firstName}`,
    paragraphs: [
      `${approvedBy} approved your Yard Link account for ${company}. Sign in with the email and password you chose when you signed up.`,
    ],
    button: link ? { label: 'Sign In', url: link } : undefined,
    notes: ['On an iPhone, open the Yard Link app, scan the code your dispatcher shows you, and sign in.'],
  })
  await sendMailQuietly(db, { to: user.email, subject: `Your ${company} account is approved`, ...message }, 'approval notice')
}

/** Goes to both addresses so a change the person did not make is noticed. */
export async function sendEmailChangedEmail(db: DbExecutor, input: {
  firstName: string
  oldEmail: string
  newEmail: string
}): Promise<void> {
  const company = await companyName(db)
  const message = renderEmail({
    companyName: company,
    preview: 'The sign-in email for your account was changed.',
    heading: 'Your sign-in email was changed',
    paragraphs: [
      `Hi ${input.firstName}, the sign-in email for your Yard Link account is now ${input.newEmail}. It was ${input.oldEmail}.`,
    ],
    notes: ['If you did not make this change, tell your dispatcher right away.'],
  })
  const subject = 'Your Yard Link sign-in email was changed'
  await sendMailQuietly(db, { to: input.newEmail, subject, ...message }, 'email-change notice')
  if (input.oldEmail.toLowerCase() !== input.newEmail.toLowerCase()) {
    await sendMailQuietly(db, { to: input.oldEmail, subject, ...message }, 'email-change notice')
  }
}

/** Tell dispatchers who asked for it that someone is waiting for approval. */
export async function sendSignupWaitingEmails(db: DbExecutor, input: {
  companyId: string
  personName: string
  roleLabel: string
}): Promise<void> {
  const dispatchers = await db
    .select({ email: users.email, firstName: users.firstName })
    .from(users)
    .innerJoin(companyMemberships, eq(companyMemberships.userId, users.id))
    .where(and(
      eq(companyMemberships.companyId, input.companyId),
      eq(companyMemberships.role, 'ADMIN'),
      eq(companyMemberships.status, 'ACTIVE'),
      wantsEmail('signups'),
    ))
  if (!dispatchers.length) return

  const company = await companyName(db)
  const link = await linkTo(db, '/admin/drivers')
  for (const dispatcher of dispatchers) {
    const message = renderEmail({
      companyName: company,
      preview: `${input.personName} is waiting for approval.`,
      heading: 'A new account is waiting',
      paragraphs: [
        `Hi ${dispatcher.firstName}, ${input.personName} signed up as a ${input.roleLabel.toLowerCase()} and is waiting for a dispatcher to approve the account.`,
      ],
      button: link ? { label: 'Review Accounts', url: link } : undefined,
    })
    await sendMailQuietly(db, { to: dispatcher.email, subject: `${input.personName} is waiting for approval`, ...message }, 'sign-up notice')
  }
}

/* ── Work ────────────────────────────────────────────────────────────── */

/** A copy of the day's work for a driver who asked for assignments by email. */
export async function sendAssignmentEmail(db: DbExecutor, input: {
  driverUserId: string
  workDate: string
  dispatcherName: string
  kind: 'assigned' | 'updated'
  tasks: DispatchTaskView[]
}): Promise<void> {
  if (!input.tasks.length) return
  const [driver] = await db
    .select({ email: users.email, firstName: users.firstName })
    .from(users)
    .where(and(eq(users.id, input.driverUserId), wantsEmail('assignments')))
    .limit(1)
  if (!driver) return

  const company = await companyName(db)
  const day = formatWorkDate(input.workDate)
  const link = await linkTo(db, '/tasks')
  const message = renderEmail({
    companyName: company,
    preview: `${input.tasks.length} ${input.tasks.length === 1 ? 'task' : 'tasks'} for ${day}.`,
    heading: input.kind === 'assigned' ? `Your work for ${day}` : `Your work for ${day} changed`,
    paragraphs: [
      `Hi ${driver.firstName}, ${input.dispatcherName} ${input.kind === 'assigned' ? 'assigned your work' : 'updated your work'} for ${day}.`,
    ],
    items: input.tasks.map((task) => {
      const box = displayContainerNumber(task.card.containerNumber)
      const from = task.card.locationName
      const to = task.card.destinationLocationName
      const route = from && to && to !== from ? `${from} to ${to}` : (from || to || '')
      return {
        title: [DISPATCH_TASK_KIND_LABELS[task.kind], box].filter(Boolean).join(' · '),
        detail: [route, task.card.notes].filter(Boolean).join('\n') || undefined,
      }
    }),
    button: link ? { label: 'Open Tasks', url: link } : undefined,
    notes: ['You get this email because you turned on Work assignments in your Yard Link settings.'],
  })
  const subject = input.kind === 'assigned' ? `Work for ${day}` : `Work updated for ${day}`
  await sendMailQuietly(db, { to: driver.email, subject, ...message }, 'assignment notice')
}

/**
 * A copy of a new message for the people on the other side of the
 * conversation who asked for messages by email. Sent for the first unread
 * message only, so a busy conversation is one email, not twenty.
 */
export async function sendMessageEmails(db: DbExecutor, input: {
  thread: typeof messageThreads.$inferSelect
  messageId: string
  senderUserId: string
  senderName: string
  body: string
}): Promise<void> {
  const { thread } = input
  const wanted = wantsEmail('messages')
  // Someone with an earlier unread message here has already been told.
  const nothingElseUnread = sql`not exists (
    select 1 from messages m
    left join message_reads r on r.thread_id = m.thread_id and r.user_id = ${users.id}
    where m.thread_id = ${thread.id}
      and m.id <> ${input.messageId}
      and m.sender_user_id is distinct from ${users.id}
      and (r.last_read_at is null or m.created_at > r.last_read_at)
  )`

  // A driver writing to dispatch reaches every dispatcher, who share the
  // conversation. Anything else has exactly one person on the other side.
  const toDispatch = thread.kind === 'DISPATCH' && thread.driverUserId === input.senderUserId
  const otherId = thread.kind === 'DISPATCH'
    ? thread.driverUserId
    : (thread.userLowId === input.senderUserId ? thread.userHighId : thread.userLowId)
  if (!toDispatch && !otherId) return
  const audience = toDispatch
    ? and(eq(companyMemberships.role, 'ADMIN'), ne(users.id, input.senderUserId))
    : eq(users.id, otherId!)

  const recipients = await db
    .select({ email: users.email, firstName: users.firstName })
    .from(users)
    .innerJoin(companyMemberships, eq(companyMemberships.userId, users.id))
    .where(and(
      eq(companyMemberships.companyId, thread.companyId),
      eq(companyMemberships.status, 'ACTIVE'),
      audience,
      wanted,
      nothingElseUnread,
    ))
  if (!recipients.length) return

  const company = await companyName(db)
  const link = await linkTo(db, '/messages')
  const body = input.body.trim() || 'Sent a file.'
  for (const recipient of recipients) {
    const message = renderEmail({
      companyName: company,
      preview: `${input.senderName}: ${body.slice(0, 90)}`,
      heading: `New message from ${input.senderName}`,
      paragraphs: [`Hi ${recipient.firstName}, you have a new message in Yard Link.`],
      quote: { from: input.senderName, body: body.length > 600 ? `${body.slice(0, 600)}…` : body },
      button: link ? { label: 'Open Messages', url: link } : undefined,
      notes: ['You get this email because you turned on New messages in your Yard Link settings. Reply in Yard Link, not to this email.'],
    })
    await sendMailQuietly(db, { to: recipient.email, subject: `New message from ${input.senderName}`, ...message }, 'message notice')
  }
}

/* ── Setup ───────────────────────────────────────────────────────────── */

/** The test button in the wizard and in Settings. Throws with the server's reason. */
export async function sendTestEmail(config: SmtpConfig, to: string, company: string): Promise<void> {
  const message = renderEmail({
    companyName: company,
    preview: 'Email from Yard Link is working.',
    heading: 'Email is working',
    paragraphs: [
      `This is a test from the Yard Link server for ${company}. If you are reading it, the email settings are correct.`,
      'People who sign up will get a welcome email with a link to confirm their address, and anyone can choose to get work assignments and messages by email in their own settings.',
    ],
  })
  await sendMailWith(config, { to, subject: 'Yard Link test email', ...message })
}
