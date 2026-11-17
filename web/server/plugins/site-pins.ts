import { placeUnpinnedSites } from '../services/site-placement'

/**
 * A site with an address and no pin gets one without anybody opening it.
 * Runs a minute after start (so a deploy does not wait on the geocoder),
 * then every two minutes.
 */
const FIRST_MS = 60_000
const EVERY_MS = 120_000

export default defineNitroPlugin((nitro) => {
  const sweep = async () => {
    try {
      await placeUnpinnedSites(useDb())
    }
    catch (error) {
      console.warn('[site-pins]', error instanceof Error ? error.message : error)
    }
  }

  const first = setTimeout(() => void sweep(), FIRST_MS)
  const timer = setInterval(() => void sweep(), EVERY_MS)
  nitro.hooks.hook('close', () => {
    clearTimeout(first)
    clearInterval(timer)
  })
})
