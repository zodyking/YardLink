import { deleteFuelReceipt } from '../../../services/fuel-receipts'
import { requireDriver } from '../../../utils/session'

/** Remove a receipt. The photo itself is kept in storage, only unlisted. */
export default defineEventHandler(async (event) => {
  const auth = await requireDriver(event)
  const id = getRouterParam(event, 'id')
  if (!id) throw createError({ statusCode: 400, statusMessage: 'Receipt id is required.' })

  const removed = await deleteFuelReceipt(useDb(), auth.companyId, auth.driverId, id)
  if (!removed) throw createError({ statusCode: 404, statusMessage: 'Receipt not found.' })

  return { ok: true }
})
