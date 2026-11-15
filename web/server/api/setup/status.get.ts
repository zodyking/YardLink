import { databaseStatus } from '../../utils/database-config'
import { currentDatabaseUrl } from '../../utils/db'
import { needsSetup } from '../../utils/setup'

/**
 * Public. Tells the web app whether to show the first-run setup wizard, and
 * which database the wizard would be writing to.
 */
export default defineEventHandler(async () => {
  return {
    needsSetup: await needsSetup(useDb()),
    database: databaseStatus(currentDatabaseUrl()),
  }
})
