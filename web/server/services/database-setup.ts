import { join } from 'node:path'
import { drizzle } from 'drizzle-orm/node-postgres'
import { migrate } from 'drizzle-orm/node-postgres/migrator'
import pg from 'pg'
import { poolOptions } from '../utils/db'

/** PostgreSQL 13 is the first release with `gen_random_uuid()` built in. */
const MINIMUM_SERVER_VERSION = 130000

/** Same folder the container's start-up migrator reads. */
function migrationsFolder(): string {
  return process.env.YARDLINK_MIGRATIONS_DIR || join(process.cwd(), 'drizzle')
}

/** Turn a driver error into a sentence the person setting up can act on. */
function explain(error: unknown): string {
  const code = (error as { code?: string }).code ?? ''
  const detail = error instanceof Error ? error.message : String(error)
  if (code === 'ENOTFOUND' || code === 'EAI_AGAIN') return 'That host name could not be found. Check the address in the connection string.'
  if (code === 'ECONNREFUSED') return 'The database refused the connection. Check the host and port, and that it accepts connections from this server.'
  if (code === 'ETIMEDOUT' || /timeout/i.test(detail)) return 'The database did not answer in time. Check the address and that a firewall is not blocking this server.'
  if (code === '28P01' || code === '28000') return 'The database rejected the user name or password.'
  if (code === '3D000') return 'That database does not exist on the server. Create it first, then try again.'
  if (code === '42501') return 'That user is not allowed to create tables in the database. Give it ownership of the database.'
  if (/ssl|tls|certificate/i.test(detail)) return `The secure connection failed: ${detail}. If your provider requires SSL, add ?sslmode=require to the end of the connection string.`
  return `The database could not be used: ${detail}`
}

/**
 * Check a database the person entered in the setup wizard and create the Yard
 * Link tables in it. An existing Yard Link database is brought up to date and
 * its records are kept.
 */
export async function prepareDatabase(connectionString: string): Promise<void> {
  const pool = new pg.Pool({ ...poolOptions(connectionString), max: 2 })
  try {
    const version = await pool.query<{ server_version_num: string }>('show server_version_num')
    if (Number(version.rows[0]?.server_version_num) < MINIMUM_SERVER_VERSION) {
      throw createError({ statusCode: 422, statusMessage: 'Yard Link needs PostgreSQL 13 or newer. This database is older.' })
    }
    await migrate(drizzle(pool), { migrationsFolder: migrationsFolder() })
  }
  catch (error) {
    if ((error as { statusCode?: number }).statusCode) throw error
    console.warn('[setup] external database could not be prepared', error)
    throw createError({ statusCode: 422, statusMessage: explain(error) })
  }
  finally {
    await pool.end().catch(() => {})
  }
}
