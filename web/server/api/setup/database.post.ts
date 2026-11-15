import { z } from 'zod'
import { checkDatabaseUrl } from '#shared/utils/database-url'
import { prepareDatabase } from '../../services/database-setup'
import { databaseSource, databaseStatus, storeDatabaseUrl } from '../../utils/database-config'
import { currentDatabaseUrl, switchDatabase } from '../../utils/db'
import { loadCompanySettings } from '../../utils/settings'
import { needsSetup } from '../../utils/setup'

const schema = z.object({
  url: z.string().trim().min(1, 'Paste the connection string for your PostgreSQL database.').max(2000),
})

/**
 * First-run setup, step one: use an external PostgreSQL database.
 *
 * Only works before the first dispatcher account exists. The database is
 * checked and prepared, remembered for the next start, and the running server
 * moves to it straight away — nothing has to be restarted.
 *
 * When the database already holds a Yard Link company (a server that was
 * redeployed), setup is over: the answer says so and the person signs in.
 */
export default defineEventHandler(async (event) => {
  const body = await readValidatedJson(event, schema)

  if (!(await needsSetup(useDb()))) {
    throw createError({ statusCode: 409, statusMessage: 'Yard Link is already set up. Sign in to continue.' })
  }
  if (databaseSource() === 'env') {
    throw createError({
      statusCode: 409,
      statusMessage: 'This server already gets its database from the DATABASE_URL setting of the host. Change it there.',
    })
  }

  const check = checkDatabaseUrl(body.url)
  if (!check.ok) {
    throw createError({ statusCode: 422, statusMessage: check.message })
  }

  await prepareDatabase(check.url)
  storeDatabaseUrl(check.url)
  await switchDatabase(check.url)
  await loadCompanySettings(useDb(), { fresh: true })

  return {
    ok: true,
    needsSetup: await needsSetup(useDb()),
    database: databaseStatus(currentDatabaseUrl()),
  }
})
