import { and, eq, inArray, ne } from 'drizzle-orm'
import { DISPATCH_TASK_KIND_LABELS } from '#shared/utils/domain'
import { displayContainerNumber } from '#shared/utils/dispatch-cards'
import { companyMemberships, deviceTokens, drivers, messageThreads, users } from '../database/schema'
import type { DbExecutor } from '../utils/db'
import { loadPushConfig, type PushConfig } from '../utils/push-settings'
import { explainApnsReason, sendApns, type ApnsPayload } from './apns'
import { logPush } from '../utils/push-log'
import type { DispatchTaskView } from './tasks'

/**
 * Push notices to the phones signed in to Yard Link. Email is a copy people
 * switch on per topic; push is how the app tells them something happened, so
 * it goes to every phone that person has signed in on.
 */

type Device = { token: string, sandbox: boolean }

async function devicesFor(db: DbExecutor, userIds: readonly string[]): Promise<Device[]> {
  if (!userIds.length) return []
  return db
    .select({ token: deviceTokens.token, sandbox: deviceTokens.sandbox })
    .from(deviceTokens)
    .where(inArray(deviceTokens.userId, [...userIds]))
}

async function forget(db: DbExecutor, tokens: readonly string[]): Promise<void> {
  if (!tokens.length) return
  await db.delete(deviceTokens).where(inArray(deviceTokens.token, [...tokens]))
}

interface Delivery {
  sent: number
  failed: number
  reasons: string[]
}

/** Hand a notice to Apple for each phone, on whichever service that phone is on. */
async function deliver(db: DbExecutor, config: PushConfig, devices: Device[], payload: ApnsPayload): Promise<Delivery> {
  const delivery: Delivery = { sent: 0, failed: 0, reasons: [] }
  for (const sandbox of [false, true]) {
    const tokens = devices.filter(device => device.sandbox === sandbox).map(device => device.token)
    if (!tokens.length) continue
    try {
      const result = await sendApns({ ...config, sandbox }, tokens, payload)
      await forget(db, result.expired)
      delivery.sent += result.sent
      delivery.failed += result.failed + result.expired.length
      for (const reason of result.reasons) if (!delivery.reasons.includes(reason)) delivery.reasons.push(reason)
    }
    catch (error) {
      console.warn('[push] could not reach Apple', error)
      delivery.failed += tokens.length
      if (!delivery.reasons.includes('NetworkError')) delivery.reasons.push('NetworkError')
    }
  }
  return delivery
}

/**
 * Send to a set of people. Every outcome, including "nobody to send to" and
 * "push is off", is logged so Settings can say why a phone stayed quiet.
 */
async function push(db: DbExecutor, kind: string, userIds: readonly string[], payload: ApnsPayload): Promise<void> {
  const config = await loadPushConfig(db)
  if (!config) {
    logPush({ kind, outcome: 'off', sent: 0, detail: 'Push is not set up. Add the Apple key under Settings.' })
    return
  }
  const devices = await devicesFor(db, userIds)
  if (!devices.length) {
    logPush({ kind, outcome: 'nobody', sent: 0, detail: 'No phone is signed in for the person this was for.' })
    return
  }
  const delivery = await deliver(db, config, devices, payload)
  logPush({
    kind,
    outcome: delivery.sent ? 'sent' : 'failed',
    sent: delivery.sent,
    detail: delivery.failed
      ? delivery.reasons.map(explainApnsReason).join(' ')
      : `Sent to ${delivery.sent} ${delivery.sent === 1 ? 'phone' : 'phones'}.`,
  })
}

/** Work assigned or changed for the day. */
export async function pushAssignment(db: DbExecutor, input: {
  driverUserId: string
  workDate: string
  dispatcherName: string
  kind: 'assigned' | 'updated'
  tasks: DispatchTaskView[]
}): Promise<void> {
  if (!input.tasks.length) return
  const first = input.tasks[0]
  const box = first ? displayContainerNumber(first.card.containerNumber) : ''
  const lead = first ? [DISPATCH_TASK_KIND_LABELS[first.kind], box].filter(Boolean).join(' · ') : ''
  const more = input.tasks.length - 1
  await push(db, 'work', [input.driverUserId], {
    title: input.kind === 'assigned' ? 'New work for you' : 'Your work changed',
    body: [lead, more > 0 ? `and ${more} more` : ''].filter(Boolean).join(' ') || `${input.tasks.length} tasks`,
    threadId: `tasks-${input.workDate}`,
    data: { screen: 'tasks', workDate: input.workDate },
  })
}

/** A new message, to everyone on the other side of the thread. */
export async function pushMessage(db: DbExecutor, input: {
  thread: typeof messageThreads.$inferSelect
  senderUserId: string
  senderName: string
  body: string
}): Promise<void> {
  const { thread } = input
  const toDispatch = thread.kind === 'DISPATCH' && thread.driverUserId === input.senderUserId
  const otherId = thread.kind === 'DISPATCH'
    ? thread.driverUserId
    : (thread.userLowId === input.senderUserId ? thread.userHighId : thread.userLowId)
  if (!toDispatch && !otherId) return
  const audience = toDispatch
    ? and(eq(companyMemberships.role, 'ADMIN'), ne(users.id, input.senderUserId))
    : eq(users.id, otherId!)

  const recipients = await db
    .select({ id: users.id })
    .from(users)
    .innerJoin(companyMemberships, eq(companyMemberships.userId, users.id))
    .where(and(
      eq(companyMemberships.companyId, thread.companyId),
      eq(companyMemberships.status, 'ACTIVE'),
      audience,
    ))
  if (!recipients.length) return

  const body = input.body.trim() || 'Sent a file.'
  await push(db, 'message', recipients.map(row => row.id), {
    title: input.senderName,
    body: body.length > 160 ? `${body.slice(0, 160)}…` : body,
    threadId: thread.id,
    // The app's service extension turns this into a message from a person.
    category: 'YARDLINK_MESSAGE',
    data: {
      screen: 'messages',
      threadId: thread.id,
      senderName: input.senderName,
      senderUserId: input.senderUserId,
    },
  })
}

/**
 * The phone crossed into a site's circle. The driver is asked, with the two
 * answers on the notification itself, and told when it will settle itself.
 */
export async function pushArrivalQuestion(db: DbExecutor, input: {
  driverId: string
  arrivalId: string
  locationName: string
  waitMinutes: number
}): Promise<void> {
  const [driver] = await db
    .select({ userId: drivers.userId })
    .from(drivers)
    .where(eq(drivers.id, input.driverId))
    .limit(1)
  if (!driver) return
  await push(db, 'arrival', [driver.userId], {
    title: `Arrived at ${input.locationName}?`,
    body: `Yard Link will record the arrival in ${input.waitMinutes} minutes unless you say otherwise.`,
    threadId: `arrival-${input.arrivalId}`,
    category: 'YARDLINK_ARRIVAL',
    data: { screen: 'arrival', arrivalId: input.arrivalId, locationName: input.locationName },
  })
}

/** Remember a phone, or refresh what we know about one. */
export async function rememberDevice(db: DbExecutor, input: {
  userId: string
  companyId: string
  token: string
  sandbox: boolean
  appVersion: string | null
}): Promise<void> {
  const now = new Date()
  await db
    .insert(deviceTokens)
    .values({
      userId: input.userId,
      companyId: input.companyId,
      token: input.token,
      platform: 'ios',
      sandbox: input.sandbox,
      appVersion: input.appVersion,
      lastSeenAt: now,
    })
    .onConflictDoUpdate({
      target: deviceTokens.token,
      set: {
        userId: input.userId,
        companyId: input.companyId,
        sandbox: input.sandbox,
        appVersion: input.appVersion,
        lastSeenAt: now,
      },
    })
}

export async function forgetDevice(db: DbExecutor, token: string): Promise<void> {
  await forget(db, [token])
}

/** Sends a test notice to the person's own phones, and says exactly what went wrong if it fails. */
export async function testPush(db: DbExecutor, userId: string): Promise<{ sent: number, devices: number }> {
  const config = await loadPushConfig(db)
  if (!config) {
    logPush({ kind: 'test', outcome: 'off', sent: 0, detail: 'Push is not set up.' })
    throw createError({ statusCode: 422, statusMessage: 'Push notifications are not set up yet. A dispatcher adds the Apple key under Settings, then Push.' })
  }
  const devices = await devicesFor(db, [userId])
  if (!devices.length) {
    logPush({ kind: 'test', outcome: 'nobody', sent: 0, detail: 'No phone is signed in for this person.' })
    throw createError({ statusCode: 422, statusMessage: 'This phone has not registered with the server. Allow notifications, then close and reopen Yard Link.' })
  }
  const delivery = await deliver(db, config, devices, {
    title: 'Yard Link',
    body: 'Push notifications are working.',
    data: { screen: 'home' },
  })
  const detail = delivery.sent
    ? `Sent to ${delivery.sent} of ${devices.length} ${devices.length === 1 ? 'phone' : 'phones'}.`
    : delivery.reasons.map(explainApnsReason).join(' ')
  logPush({ kind: 'test', outcome: delivery.sent ? 'sent' : 'failed', sent: delivery.sent, detail })
  if (!delivery.sent) throw createError({ statusCode: 422, statusMessage: detail })
  return { sent: delivery.sent, devices: devices.length }
}
