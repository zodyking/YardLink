/**
 * The last few push attempts, kept in memory so Settings can show why a phone
 * did not buzz. Cleared when the server restarts; nothing here is a record.
 */
export interface PushLogEntry {
  at: string
  /** What the notice was: message, work, arrival, test. */
  kind: string
  outcome: 'sent' | 'off' | 'nobody' | 'failed'
  sent: number
  detail: string
}

const MAX = 20
const entries: PushLogEntry[] = []

export function logPush(entry: Omit<PushLogEntry, 'at'>): void {
  entries.unshift({ at: new Date().toISOString(), ...entry })
  entries.length = Math.min(entries.length, MAX)
  if (entry.outcome !== 'sent') console.warn(`[push] ${entry.kind}: ${entry.outcome}. ${entry.detail}`)
}

export function recentPushes(): PushLogEntry[] {
  return [...entries]
}
