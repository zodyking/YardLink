import { drizzle } from 'drizzle-orm/node-postgres'
import type { NodePgDatabase } from 'drizzle-orm/node-postgres'
import pg from 'pg'
import * as schema from '../database/schema'

export { schema }

let pool: pg.Pool | undefined
let db: NodePgDatabase<typeof schema> | undefined
/** Set when the setup wizard points the running server at another database. */
let switchedUrl = ''

function sslOption() {
  const config = useRuntimeConfig()
  return (config.databaseSsl || process.env.NUXT_DATABASE_SSL) === 'true'
    ? { rejectUnauthorized: false }
    : undefined
}

/** The connection string in use right now. */
export function currentDatabaseUrl(): string {
  return switchedUrl || useRuntimeConfig().databaseUrl || process.env.DATABASE_URL || ''
}

/** Pool settings shared by the app and by one-off checks of a new database. */
export function poolOptions(connectionString: string): pg.PoolConfig {
  return {
    connectionString,
    ssl: sslOption(),
    max: 10,
    idleTimeoutMillis: 30_000,
    connectionTimeoutMillis: 10_000,
  }
}

/**
 * Lazily-created connection pool. Nitro keeps the module alive for the process
 * lifetime, so a single pool is shared across requests.
 */
export function useDb(): NodePgDatabase<typeof schema> {
  if (db) return db

  const connectionString = currentDatabaseUrl()
  if (!connectionString) {
    throw createError({
      statusCode: 500,
      statusMessage: 'DATABASE_URL is not configured.',
    })
  }

  pool = new pg.Pool(poolOptions(connectionString))
  pool.on('error', (error) => {
    console.error('[db] idle client error', error)
  })

  db = drizzle(pool, { schema })
  return db
}

/**
 * Point the running server at another database. Used once, by the setup
 * wizard, after the new database has been checked and prepared.
 */
export async function switchDatabase(connectionString: string): Promise<void> {
  const previous = pool
  switchedUrl = connectionString
  pool = undefined
  db = undefined
  useDb()
  if (previous) {
    await previous.end().catch(error => console.warn('[db] closing the previous pool failed', error))
  }
}

export type Database = NodePgDatabase<typeof schema>
/** Transaction handle passed to service functions that must be atomic. */
export type DbTransaction = Parameters<Parameters<Database['transaction']>[0]>[0]
export type DbExecutor = Database | DbTransaction
