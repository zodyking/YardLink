import { backfillDutyCycles } from '../services/duty-cycles'

/**
 * Gives history recorded before duty cycles existed its cycle records. Runs
 * after boot so a large backfill never delays the first request, and only
 * touches containers that have no cycles yet.
 */
export default defineNitroPlugin(() => {
  setTimeout(async () => {
    try {
      const built = await backfillDutyCycles(useDb())
      if (built) console.info(`[duty-cycles] backfilled ${built} cycle(s) from existing history.`)
    }
    catch (error) {
      console.warn('[duty-cycles] backfill skipped:', error instanceof Error ? error.message : error)
    }
  }, 5_000)
})
