import { settleDueArrivals } from '../services/arrivals'

/**
 * The wait on an arrival question runs here, not on the phone, so it still
 * ends when the phone is asleep, out of signal, or the app was killed. One
 * tick a minute; each arrival is stamped at its own crossing, so a late tick
 * never shifts a time.
 */
const TICK_MS = 60_000

export default defineNitroPlugin((nitro) => {
  const tick = async () => {
    try {
      await settleDueArrivals(useDb())
    }
    catch (error) {
      console.warn('[arrivals]', error instanceof Error ? error.message : error)
    }
  }

  const timer = setInterval(() => void tick(), TICK_MS)
  nitro.hooks.hook('close', () => {
    clearInterval(timer)
  })
})
