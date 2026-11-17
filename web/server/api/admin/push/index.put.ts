import { requireAdmin } from '../../../utils/session'
import { loadPushConfig, pushInputSchema, resolvePushInput, savePushConfig, summarizePush } from '../../../utils/push-settings'

/** Saves the Apple push key. The key itself is never sent back to a browser. */
export default defineEventHandler(async (event) => {
  const auth = await requireAdmin(event)
  const body = await readValidatedJson(event, pushInputSchema)
  const db = useDb()
  const config = resolvePushInput(body, await loadPushConfig(db))
  await savePushConfig(db, auth.companyId, config)
  return { ok: true, push: summarizePush(config) }
})
