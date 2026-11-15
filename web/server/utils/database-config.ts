import { chmodSync, mkdirSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { checkDatabaseUrl, describeDatabase } from '#shared/utils/database-url'
import { dataDirectory } from '../services/storage'

/**
 * Which PostgreSQL database this server uses.
 *
 * - `builtin`: the database container that ships in docker-compose.yml.
 * - `wizard`: an external database entered in the setup wizard. The string is
 *   kept in the data volume so the container finds it on its next start.
 * - `env`: an external database passed as DATABASE_URL by the host.
 *
 * The container's entrypoint decides this at start and reports it in
 * YARDLINK_DATABASE_SOURCE; without an entrypoint (development) the address
 * can only have come from the environment.
 */
export type DatabaseSource = 'builtin' | 'wizard' | 'env'

/** Kept in step with docker/entrypoint.sh, which reads the same file. */
function storedUrlPath(): string {
  return join(dataDirectory(), 'config', 'database-url')
}

let source: DatabaseSource | undefined

export function databaseSource(): DatabaseSource {
  if (source) return source
  const reported = process.env.YARDLINK_DATABASE_SOURCE
  source = reported === 'builtin' || reported === 'wizard' ? reported : 'env'
  return source
}

/** Remember an external database so the next container start uses it too. */
export function storeDatabaseUrl(url: string): void {
  const path = storedUrlPath()
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, `${url}\n`, { mode: 0o600 })
  chmodSync(path, 0o600)
  source = 'wizard'
}

/** What Settings and the wizard show about the database. Never a password. */
export function databaseStatus(currentUrl: string): { source: DatabaseSource, external: boolean, label: string } {
  const current = databaseSource()
  const check = checkDatabaseUrl(currentUrl)
  return {
    source: current,
    external: current !== 'builtin',
    label: current === 'builtin'
      ? 'Built-in database'
      : check.ok ? describeDatabase(check.summary) : 'External database',
  }
}
