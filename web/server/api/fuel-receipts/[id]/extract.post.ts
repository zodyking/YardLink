import { rereadFuelReceipt } from '../../../services/fuel-receipts'
import { requireDriver } from '../../../utils/session'

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

/**
 * Read a saved receipt's photo again and suggest its fields, for a receipt
 * saved before a field existed or read badly the first time. Nothing is
 * saved; the app fills in what was blank and the driver saves from there.
 */
export default defineEventHandler(async (event) => {
  const auth = await requireDriver(event)
  const id = getRouterParam(event, 'id')
  if (!id || !UUID_RE.test(id)) {
    throw createError({ statusCode: 400, statusMessage: 'Receipt id is required.' })
  }

  const extraction = await rereadFuelReceipt(useDb(), auth.companyId, auth.driverId, id)
  if (!extraction) throw createError({ statusCode: 404, statusMessage: 'Receipt not found.' })
  return { extraction }
})
