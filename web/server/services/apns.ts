import { connect, constants, type ClientHttp2Session } from 'node:http2'
import { createPrivateKey, sign as signRaw } from 'node:crypto'
import type { PushConfig } from '../utils/push-settings'

/**
 * Apple Push Notification service over HTTP/2, with the provider token Apple
 * asks for: an ES256 JWT signed with the .p8 key, good for an hour. Nothing
 * here needs a library — Node signs ES256 and speaks HTTP/2 on its own.
 */

const HOST_PRODUCTION = 'https://api.push.apple.com'
const HOST_SANDBOX = 'https://api.sandbox.push.apple.com'
/** Apple rejects a token older than an hour; it also refuses one minted too often. */
const TOKEN_LIFETIME_MS = 45 * 60 * 1000

export type ApnsPayload = {
  title: string
  body: string
  /** Shown over the app icon. Pass 0 to clear it. */
  badge?: number
  threadId?: string
  /** Travels with the notification so a tap can open the right screen. */
  data?: Record<string, string>
  /** Lets the app's service extension rewrite it as a message from a person. */
  category?: string
}

export type ApnsResult = {
  sent: number
  /** Tokens Apple says are dead, to be deleted. */
  expired: string[]
  failed: number
  /** Apple's own words for each refusal, without repeats. */
  reasons: string[]
}

/** What Apple's refusal means, and what to do about it, in plain words. */
export function explainApnsReason(reason: string): string {
  switch (reason) {
    case 'InvalidProviderToken':
    case 'ExpiredProviderToken':
    case 'MissingProviderToken':
      return 'Apple did not accept the key. Check the Key ID, the Team ID and that the whole .p8 file was pasted.'
    case 'BadEnvironmentKeyInToken':
      return 'The key is not allowed for this kind of build. In Apple Developer, make the key work for both Sandbox and Production.'
    case 'TopicDisallowed':
    case 'BadTopic':
    case 'MissingTopic':
    case 'DeviceTokenNotForTopic':
      return 'The Bundle ID in Settings does not match the app. It must be exactly com.zodyking.yardlink.'
    case 'BadDeviceToken':
      return 'This phone registered with the other Apple service. Close Yard Link, open it again and try once more.'
    case 'Unregistered':
      return 'Apple says the app was removed from this phone. Sign in again.'
    case 'Forbidden':
      return 'Apple refused the key for this app. Check the Team ID and that the key has Push Notifications turned on.'
    case 'TooManyProviderTokenUpdates':
      return 'Apple is rate limiting. Try again in a few minutes.'
    case 'NetworkError':
      return 'The server could not reach Apple.'
    default:
      return reason ? `Apple answered: ${reason}.` : 'Apple did not answer.'
  }
}

function base64url(value: Buffer | string): string {
  return Buffer.from(value).toString('base64url')
}

/** DER (r,s sequence) → the fixed 64-byte JOSE form. */
function joseSignature(der: Buffer): Buffer {
  let offset = 2
  if (der[1] !== undefined && der[1] > 0x80) offset += der[1] - 0x80
  const readInt = (): Buffer => {
    const length = der[offset + 1] ?? 0
    const start = offset + 2
    const value = der.subarray(start, start + length)
    offset = start + length
    const trimmed = value[0] === 0 ? value.subarray(1) : value
    return Buffer.concat([Buffer.alloc(Math.max(0, 32 - trimmed.length)), trimmed])
  }
  const r = readInt()
  const s = readInt()
  return Buffer.concat([r, s])
}

const tokens = new Map<string, { value: string, mintedAt: number }>()

function providerToken(config: PushConfig): string {
  const cacheKey = `${config.teamId}:${config.keyId}`
  const cached = tokens.get(cacheKey)
  if (cached && Date.now() - cached.mintedAt < TOKEN_LIFETIME_MS) return cached.value

  const header = base64url(JSON.stringify({ alg: 'ES256', kid: config.keyId }))
  const claims = base64url(JSON.stringify({ iss: config.teamId, iat: Math.floor(Date.now() / 1000) }))
  const key = createPrivateKey(config.signingKey)
  const der = signRaw('sha256', Buffer.from(`${header}.${claims}`), key)
  const value = `${header}.${claims}.${base64url(joseSignature(der))}`
  tokens.set(cacheKey, { value, mintedAt: Date.now() })
  return value
}

/** Apple's reason strings for a token that will never work again. */
const DEAD_TOKEN_REASONS = new Set(['BadDeviceToken', 'Unregistered', 'DeviceTokenNotForTopic'])

function body(payload: ApnsPayload): string {
  const aps: Record<string, unknown> = {
    alert: { title: payload.title, body: payload.body },
    sound: 'default',
    'mutable-content': 1,
  }
  if (typeof payload.badge === 'number') aps.badge = payload.badge
  if (payload.threadId) aps['thread-id'] = payload.threadId
  if (payload.category) aps.category = payload.category
  return JSON.stringify({ aps, ...(payload.data ?? {}) })
}

function openSession(config: PushConfig): Promise<ClientHttp2Session> {
  return new Promise((resolve, reject) => {
    const session = connect(config.sandbox ? HOST_SANDBOX : HOST_PRODUCTION)
    const timer = setTimeout(() => fail(new Error('Apple did not answer in time.')), 10_000)
    function fail(error: Error) {
      clearTimeout(timer)
      session.destroy()
      reject(error)
    }
    session.once('error', fail)
    session.once('connect', () => {
      clearTimeout(timer)
      session.removeListener('error', fail)
      session.on('error', () => {})
      resolve(session)
    })
  })
}

function post(
  session: ClientHttp2Session,
  config: PushConfig,
  authorization: string,
  deviceToken: string,
  payload: string,
): Promise<{ status: number, reason: string }> {
  return new Promise((resolve) => {
    const request = session.request({
      [constants.HTTP2_HEADER_METHOD]: 'POST',
      [constants.HTTP2_HEADER_PATH]: `/3/device/${deviceToken}`,
      [constants.HTTP2_HEADER_AUTHORITY]: config.sandbox ? 'api.sandbox.push.apple.com' : 'api.push.apple.com',
      authorization: `bearer ${authorization}`,
      'apns-topic': config.bundleId,
      'apns-push-type': 'alert',
      'apns-priority': '10',
      [constants.HTTP2_HEADER_CONTENT_TYPE]: 'application/json',
    })
    let status = 0
    let text = ''
    request.setEncoding('utf8')
    request.on('response', headers => { status = Number(headers[constants.HTTP2_HEADER_STATUS]) || 0 })
    request.on('data', chunk => { text += chunk })
    request.on('error', () => resolve({ status: 0, reason: 'NetworkError' }))
    request.on('end', () => {
      let reason = ''
      if (text) {
        try {
          reason = String((JSON.parse(text) as { reason?: string }).reason ?? '')
        }
        catch {
          reason = ''
        }
      }
      resolve({ status, reason })
    })
    request.setTimeout(10_000, () => request.close())
    request.end(payload)
  })
}

/** Send one notification to every token, on a single connection. */
export async function sendApns(
  config: PushConfig,
  deviceTokens: readonly string[],
  payload: ApnsPayload,
): Promise<ApnsResult> {
  const result: ApnsResult = { sent: 0, expired: [], failed: 0, reasons: [] }
  if (!deviceTokens.length) return result

  const authorization = providerToken(config)
  const text = body(payload)
  const session = await openSession(config)
  try {
    const answers = await Promise.all(
      deviceTokens.map(async (deviceToken) => {
        const answer = await post(session, config, authorization, deviceToken, text)
        return { deviceToken, ...answer }
      }),
    )
    for (const answer of answers) {
      if (answer.status === 200) {
        result.sent += 1
        continue
      }
      if (DEAD_TOKEN_REASONS.has(answer.reason)) result.expired.push(answer.deviceToken)
      else result.failed += 1
      const reason = answer.reason || (answer.status ? `HTTP ${answer.status}` : 'NetworkError')
      if (!result.reasons.includes(reason)) result.reasons.push(reason)
    }
  }
  finally {
    session.close()
  }
  return result
}
