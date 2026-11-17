import { and, eq, inArray, ne } from 'drizzle-orm'
import { DISPATCH_TASK_KIND_LABELS } from '#shared/utils/domain'
import { displayContainerNumber } from '#shared/utils/dispatch-cards'
import { companyMemberships, deviceTokens, drivers, messageThreads, users } from '../database/schema'
import type { DbExecutor } from '../utils/db'
import { loadPushConfig, type PushConfig } from '../utils/push-settings'
import { sendApns, type ApnsPayload } from './apns'
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

/** Send to a set of people, on whichever of Apple's two services they are on. */
async function push(db: DbExecutor, userIds: readonly string[], payload: ApnsPayload): Promise<void> {
  const config = await loadPushConfig(db)
  if (!config) return
  const devices = await devicesFor(db, userIds)
  if (!devices.length) return

  for (const sandbox of [false, true]) {
    const tokens = devices.filter(device => device.sandbox === sandbox).map(device => device.token)
    if (!tokens.length) continue
    const target: PushConfig = { ...config, sandbox }
    try {
      const result = await sendApns(target, tokens, payload)
      await forget(db, result.expired)
    }
    catch (error) {
      console.warn('[push] could not reach Apple', error)
    }
  }
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
  await push(db, [input.driverUserId], {
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
  await push(db, recipients.map(row => row.id), {
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
  await push(db, [driver.userId], {
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

/** A quick check that the key, the team and the bundle id work together. */
export async function testPush(db: DbExecutor, userId: string): Promise<{ sent: number, devices: number }> {
  const config = await loadPushConfig(db)
  if (!config) {
    throw createError({ statusCode: 422, statusMessage: 'Set up push notifications first.' })
  }
  const devices = await devicesFor(db, [userId])
  if (!devices.length) {
    throw createError({ statusCode: 422, statusMessage: 'Sign in on an iPhone and allow notifications first.' })
  }
  let sent = 0
  for (const sandbox of [false, true]) {
    const tokens = devices.filter(device => device.sandbox === sandbox).map(device => device.token)
    if (!tokens.length) continue
    const result = await sendApns({ ...config, sandbox }, tokens, {
      title: 'Yard Link',
      body: 'Push notifications are working.',
      data: { screen: 'home' },
    })
    await forget(db, result.expired)
    sent += result.sent
  }
  if (!sent) {
    throw createError({ statusCode: 422, statusMessage: 'Apple would not take the notice. Check the key, the team ID and the bundle identifier.' })
  }
  return { sent, devices: devices.length }
}
