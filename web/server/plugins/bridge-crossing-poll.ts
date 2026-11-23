import { BRIDGE_CROSSING_POLL_INTERVAL_MS } from '#shared/utils/bridge-crossings'
import { runBridgeCrossingPoll } from '../services/bridge-crossing-poll'
import { loadCompanySettings } from '../utils/settings'

/**
 * In-process Port Authority bridge-crossing poll. One tick every 5 minutes;
 * gated by the "Bridge crossing times" switch in Settings, read fresh on
 * every tick so turning it on or off needs no restart.
 */
export default defineNitroPlugin((nitro) => {
  const tick = async () => {
    try {
      const db = useDb()
      const settings = await loadCompanySettings(db, { fresh: true })
      if (!settings.bridgeCrossingTimesEnabled) return
      await runBridgeCrossingPoll(db)
    }
    catch (error) {
      console.warn('[bridge-crossing-poll]', error instanceof Error ? error.message : error)
    }
  }

  // First point arrives shortly after boot rather than after a full interval,
  // so a company that just turned this on isn't staring at an empty page.
  setTimeout(() => void tick(), 5_000)

  const timer = setInterval(() => void tick(), BRIDGE_CROSSING_POLL_INTERVAL_MS)
  nitro.hooks.hook('close', () => {
    clearInterval(timer)
  })
})
