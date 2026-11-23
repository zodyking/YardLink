import { loadFuelReceiptFile } from '../../../services/fuel-receipts'
import { useObjectStorage } from '../../../services/storage'
import { requireDriver } from '../../../utils/session'

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

/** Authenticated receipt photo bytes — never a public object-storage URL. */
export default defineEventHandler(async (event) => {
  const auth = await requireDriver(event)
  const id = getRouterParam(event, 'id')
  if (!id || !UUID_RE.test(id)) {
    throw createError({ statusCode: 400, statusMessage: 'Receipt id is required.' })
  }

  const file = await loadFuelReceiptFile(useDb(), auth.companyId, auth.driverId, id)
  if (!file) throw createError({ statusCode: 404, statusMessage: 'Receipt not found.' })

  const body = await useObjectStorage().get(file.storageKey)
  setHeader(event, 'Content-Type', file.mimeType || 'application/octet-stream')
  setHeader(event, 'Content-Disposition', 'inline; filename="receipt.jpg"')
  setHeader(event, 'Cache-Control', 'private, max-age=120')
  setHeader(event, 'Content-Length', String(body.byteLength))
  return body
})
