import { needsSetup } from '../../utils/setup'

/** Public. Tells the web app whether to show the first-run setup wizard. */
export default defineEventHandler(async () => {
  return { needsSetup: await needsSetup(useDb()) }
})
