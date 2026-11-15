/**
 * PostgreSQL connection strings, as pasted into the setup wizard.
 *
 * Shared so the wizard can point at a mistake before anything is sent, and the
 * server applies exactly the same rule.
 */

export interface DatabaseUrlSummary {
  host: string
  port: number
  database: string
  user: string
}

export type DatabaseUrlCheck
  = | { ok: true, url: string, summary: DatabaseUrlSummary }
    | { ok: false, message: string }

const EXAMPLE = 'postgresql://user:password@host:5432/database'

export function checkDatabaseUrl(raw: unknown): DatabaseUrlCheck {
  const text = typeof raw === 'string' ? raw.trim() : ''
  if (!text) return { ok: false, message: 'Paste the connection string for your PostgreSQL database.' }
  if (!/^postgres(ql)?:\/\//i.test(text)) {
    return { ok: false, message: `Start with postgresql:// — for example ${EXAMPLE}` }
  }

  let parsed: URL
  try {
    parsed = new URL(text)
  }
  catch {
    return { ok: false, message: `That is not a complete connection string. It should look like ${EXAMPLE}` }
  }

  const database = decodeURIComponent(parsed.pathname.replace(/^\/+/, ''))
  if (!parsed.hostname) return { ok: false, message: 'The connection string has no host.' }
  if (!parsed.username) return { ok: false, message: 'The connection string has no user name.' }
  if (!database) return { ok: false, message: 'The connection string has no database name after the last slash.' }

  return {
    ok: true,
    url: text,
    summary: {
      host: parsed.hostname,
      port: Number(parsed.port) || 5432,
      database,
      user: decodeURIComponent(parsed.username),
    },
  }
}

/** `db.example.com:5432 / yardlink` — safe to show; never includes the password. */
export function describeDatabase(summary: DatabaseUrlSummary): string {
  return `${summary.host}:${summary.port} / ${summary.database}`
}
