import { and, asc, desc, eq, gt, inArray, or, sql } from 'drizzle-orm'
import type { DbExecutor } from '../utils/db'
import type { AuthContext } from '../utils/session'
import {
  companyMemberships,
  documents,
  messageReads,
  messageThreads,
  messages,
  users,
} from '../database/schema'

/**
 * Built-in messaging. This is what replaced SMS: drivers and dispatch talk
 * inside Yard Link, on the employer's own server. People who ask for it also
 * get an email copy (`services/emails.ts`).
 *
 * Every driver has one DISPATCH thread shared by all dispatchers, so whoever
 * is on the desk sees and answers it — the same job the dispatch phone number
 * did. Any two people can also open a DIRECT thread.
 */

export const MESSAGE_BODY_MAX = 4000
export const MESSAGE_KINDS = ['TEXT', 'TRIP_UPDATE', 'TASKS', 'ACCOUNT'] as const
export type MessageKind = (typeof MESSAGE_KINDS)[number]

type Thread = typeof messageThreads.$inferSelect

export async function dispatchThreadFor(db: DbExecutor, companyId: string, driverUserId: string): Promise<Thread> {
  const [existing] = await db
    .select()
    .from(messageThreads)
    .where(and(
      eq(messageThreads.companyId, companyId),
      eq(messageThreads.kind, 'DISPATCH'),
      eq(messageThreads.driverUserId, driverUserId),
    ))
    .limit(1)
  if (existing) return existing

  await db
    .insert(messageThreads)
    .values({ companyId, kind: 'DISPATCH', driverUserId })
    .onConflictDoNothing()
  const [created] = await db
    .select()
    .from(messageThreads)
    .where(and(
      eq(messageThreads.companyId, companyId),
      eq(messageThreads.kind, 'DISPATCH'),
      eq(messageThreads.driverUserId, driverUserId),
    ))
    .limit(1)
  if (!created) throw createError({ statusCode: 500, statusMessage: 'Could not open the conversation.' })
  return created
}

export async function directThreadFor(db: DbExecutor, companyId: string, a: string, b: string): Promise<Thread> {
  if (a === b) throw createError({ statusCode: 400, statusMessage: 'Pick someone else to message.' })
  const [low, high] = a < b ? [a, b] : [b, a]
  const where = and(
    eq(messageThreads.companyId, companyId),
    eq(messageThreads.kind, 'DIRECT'),
    eq(messageThreads.userLowId, low),
    eq(messageThreads.userHighId, high),
  )
  const [existing] = await db.select().from(messageThreads).where(where).limit(1)
  if (existing) return existing
  await db.insert(messageThreads).values({ companyId, kind: 'DIRECT', userLowId: low, userHighId: high }).onConflictDoNothing()
  const [created] = await db.select().from(messageThreads).where(where).limit(1)
  if (!created) throw createError({ statusCode: 500, statusMessage: 'Could not open the conversation.' })
  return created
}

/** Dispatchers see every dispatch thread; everyone sees their own threads. */
export function canSeeThread(auth: AuthContext, thread: Thread): boolean {
  if (thread.companyId !== auth.companyId) return false
  if (thread.kind === 'DISPATCH') return auth.role === 'ADMIN' || thread.driverUserId === auth.userId
  return thread.userLowId === auth.userId || thread.userHighId === auth.userId
}

export async function loadThreadFor(db: DbExecutor, auth: AuthContext, threadId: string): Promise<Thread> {
  const [thread] = await db.select().from(messageThreads).where(eq(messageThreads.id, threadId)).limit(1)
  if (!thread || !canSeeThread(auth, thread)) {
    throw createError({ statusCode: 404, statusMessage: 'Conversation not found.' })
  }
  return thread
}

function preview(body: string): string {
  const line = body.replace(/\s+/g, ' ').trim()
  return line.length > 120 ? `${line.slice(0, 117)}…` : line
}

export interface PostMessageInput {
  /** Client-generated id; a retried send with the same id is a no-op. */
  id?: string
  companyId: string
  threadId: string
  senderUserId: string | null
  senderName: string
  body: string
  kind?: MessageKind
  tripId?: string | null
  documentIds?: string[]
}

export async function postMessage(db: DbExecutor, input: PostMessageInput) {
  const body = input.body.trim().slice(0, MESSAGE_BODY_MAX)
  const documentIds = [...new Set(input.documentIds ?? [])].slice(0, 20)
  if (!body && !documentIds.length) {
    throw createError({ statusCode: 422, statusMessage: 'Write a message first.' })
  }

  if (documentIds.length) {
    const owned = await db
      .select({ id: documents.id })
      .from(documents)
      .where(and(eq(documents.companyId, input.companyId), inArray(documents.id, documentIds)))
    if (owned.length !== documentIds.length) {
      throw createError({ statusCode: 404, statusMessage: 'One of those files is no longer available.' })
    }
  }

  const id = input.id ?? crypto.randomUUID()
  const now = new Date()
  const inserted = await db
    .insert(messages)
    .values({
      id,
      companyId: input.companyId,
      threadId: input.threadId,
      senderUserId: input.senderUserId,
      senderName: input.senderName,
      body,
      kind: input.kind ?? 'TEXT',
      tripId: input.tripId ?? null,
      documentIds,
      createdAt: now,
    })
    .onConflictDoNothing({ target: messages.id })
    .returning()

  if (inserted.length) {
    await db
      .update(messageThreads)
      .set({ lastMessageAt: now, lastMessagePreview: preview(body) || 'Sent a file' })
      .where(eq(messageThreads.id, input.threadId))
    if (input.senderUserId) await markThreadRead(db, input.threadId, input.senderUserId, now)
  }

  const [row] = inserted.length
    ? inserted
    : await db.select().from(messages).where(eq(messages.id, id)).limit(1)
  return row!
}

/** A notice from Yard Link itself in a driver's dispatch thread. */
export async function postSystemNotice(db: DbExecutor, input: {
  companyId: string
  driverUserId: string
  body: string
  kind: MessageKind
  senderName?: string
}) {
  const thread = await dispatchThreadFor(db, input.companyId, input.driverUserId)
  return postMessage(db, {
    companyId: input.companyId,
    threadId: thread.id,
    senderUserId: null,
    senderName: input.senderName ?? 'Yard Link',
    body: input.body,
    kind: input.kind,
  })
}

export async function markThreadRead(db: DbExecutor, threadId: string, userId: string, at = new Date()) {
  await db
    .insert(messageReads)
    .values({ threadId, userId, lastReadAt: at })
    .onConflictDoUpdate({ target: [messageReads.threadId, messageReads.userId], set: { lastReadAt: at } })
}

function visibleThreads(auth: AuthContext) {
  const mine = or(eq(messageThreads.userLowId, auth.userId), eq(messageThreads.userHighId, auth.userId))
  const dispatch = auth.role === 'ADMIN'
    ? eq(messageThreads.kind, 'DISPATCH')
    : and(eq(messageThreads.kind, 'DISPATCH'), eq(messageThreads.driverUserId, auth.userId))
  return and(eq(messageThreads.companyId, auth.companyId), or(dispatch, mine))
}

export async function listThreads(db: DbExecutor, auth: AuthContext) {
  // A driver always has a line to dispatch, even before the first message.
  if (auth.role === 'DRIVER') await dispatchThreadFor(db, auth.companyId, auth.userId)

  const rows = await db
    .select({
      id: messageThreads.id,
      kind: messageThreads.kind,
      driverUserId: messageThreads.driverUserId,
      userLowId: messageThreads.userLowId,
      userHighId: messageThreads.userHighId,
      lastMessageAt: messageThreads.lastMessageAt,
      lastMessagePreview: messageThreads.lastMessagePreview,
      createdAt: messageThreads.createdAt,
      unread: sql<number>`(
        select count(*)::int from ${messages} m
        where m.thread_id = ${messageThreads.id}
          and (m.sender_user_id is null or m.sender_user_id <> ${auth.userId})
          and m.created_at > coalesce((
            select r.last_read_at from ${messageReads} r
            where r.thread_id = ${messageThreads.id} and r.user_id = ${auth.userId}
          ), 'epoch'::timestamptz)
      )`,
    })
    .from(messageThreads)
    .where(visibleThreads(auth))
    .orderBy(sql`${messageThreads.lastMessageAt} desc nulls last`, desc(messageThreads.createdAt))
    .limit(300)

  const otherIds = new Set<string>()
  for (const row of rows) {
    if (row.kind === 'DISPATCH') {
      if (row.driverUserId) otherIds.add(row.driverUserId)
    }
    else {
      const other = row.userLowId === auth.userId ? row.userHighId : row.userLowId
      if (other) otherIds.add(other)
    }
  }
  const people = otherIds.size
    ? await db
        .select({ id: users.id, firstName: users.firstName, lastName: users.lastName })
        .from(users)
        .where(inArray(users.id, [...otherIds]))
    : []
  const nameOf = new Map(people.map(person => [person.id, `${person.firstName} ${person.lastName}`.trim()]))

  return rows.map((row) => {
    const isOwnDispatch = row.kind === 'DISPATCH' && row.driverUserId === auth.userId
    const otherId = row.kind === 'DISPATCH'
      ? row.driverUserId
      : (row.userLowId === auth.userId ? row.userHighId : row.userLowId)
    return {
      id: row.id,
      kind: row.kind,
      title: isOwnDispatch ? 'Dispatch' : (nameOf.get(otherId ?? '') ?? 'Conversation'),
      subtitle: row.kind === 'DISPATCH' ? (isOwnDispatch ? 'Everyone on the dispatch desk' : 'Driver · dispatch line') : 'Direct message',
      otherUserId: isOwnDispatch ? null : otherId,
      lastMessageAt: row.lastMessageAt,
      lastMessagePreview: row.lastMessagePreview,
      unread: row.unread,
    }
  })
}

export async function unreadTotal(db: DbExecutor, auth: AuthContext): Promise<number> {
  const [row] = await db
    .select({
      value: sql<number>`coalesce(sum((
        select count(*) from ${messages} m
        where m.thread_id = ${messageThreads.id}
          and (m.sender_user_id is null or m.sender_user_id <> ${auth.userId})
          and m.created_at > coalesce((
            select r.last_read_at from ${messageReads} r
            where r.thread_id = ${messageThreads.id} and r.user_id = ${auth.userId}
          ), 'epoch'::timestamptz)
      )), 0)::int`,
    })
    .from(messageThreads)
    .where(visibleThreads(auth))
  return row?.value ?? 0
}

export async function listMessages(db: DbExecutor, auth: AuthContext, threadId: string, after?: Date | null) {
  const filters = [eq(messages.threadId, threadId), eq(messages.companyId, auth.companyId)]
  if (after) filters.push(gt(messages.createdAt, after))

  const rows = after
    ? await db.select().from(messages).where(and(...filters)).orderBy(asc(messages.createdAt)).limit(300)
    : (await db.select().from(messages).where(and(...filters)).orderBy(desc(messages.createdAt)).limit(300)).reverse()

  const docIds = [...new Set(rows.flatMap(row => row.documentIds ?? []))]
  const files = docIds.length
    ? await db
        .select({ id: documents.id, fileName: documents.fileName, mimeType: documents.mimeType, category: documents.category })
        .from(documents)
        .where(and(eq(documents.companyId, auth.companyId), inArray(documents.id, docIds)))
    : []
  const fileById = new Map(files.map(file => [file.id, file]))

  return rows.map(row => ({
    id: row.id,
    threadId: row.threadId,
    senderUserId: row.senderUserId,
    senderName: row.senderName,
    mine: row.senderUserId === auth.userId,
    body: row.body,
    kind: row.kind,
    tripId: row.tripId,
    documents: (row.documentIds ?? []).map(id => fileById.get(id)).filter(Boolean),
    createdAt: row.createdAt,
  }))
}

/** People this user can start a conversation with. */
export async function listContacts(db: DbExecutor, auth: AuthContext) {
  const rows = await db
    .select({
      userId: users.id,
      firstName: users.firstName,
      lastName: users.lastName,
      role: companyMemberships.role,
    })
    .from(companyMemberships)
    .innerJoin(users, eq(users.id, companyMemberships.userId))
    .where(and(
      eq(companyMemberships.companyId, auth.companyId),
      eq(companyMemberships.status, 'ACTIVE'),
      sql`${users.disabledAt} is null`,
    ))
    .orderBy(users.firstName, users.lastName)

  return rows
    .filter(row => row.userId !== auth.userId)
    .map(row => ({
      userId: row.userId,
      name: `${row.firstName} ${row.lastName}`.trim(),
      role: row.role,
    }))
}
