import { SHIPCSX_POLL_INTERVAL_MS } from '#shared/utils/csx-lookup'
import { runShipcsxPoll } from '../services/shipcsx-poll'
import { loadCompanySettings } from '../utils/settings'

/**
 * In-process ShipCSX poll. One tick every 30 minutes; the service itself
 * no-ops outside 05:00–22:00 America/New_York. Whether it runs at all is the
 * "Check ShipCSX automatically" switch in Settings, read on every tick so a
 * dispatcher can turn it on or off without restarting anything.
 */
export default defineNitroPlugin((nitro) => {
  const tick = async () => {
    try {
      const db = useDb()
      const settings = await loadCompanySettings(db, { fresh: true })
      if (!settings.shipcsxPoll) return
      await runShipcsxPoll(db)
    }
    catch (error) {
      console.warn('[shipcsx-poll]', error instanceof Error ? error.message : error)
    }
  }

  // Warm the settings cache so manual checks see the saved default terminal.
  setTimeout(() => {
    void loadCompanySettings(useDb(), { fresh: true }).catch(() => undefined)
  }, 3_000)

  const timer = setInterval(() => void tick(), SHIPCSX_POLL_INTERVAL_MS)
  nitro.hooks.hook('close', () => {
    clearInterval(timer)
  })
})
