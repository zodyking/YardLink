import { z } from 'zod'
import { extractFuelReceipt } from '../../services/fuel-receipts'
import { assertUploadAllowed } from '../../services/storage'
import { requireDriver } from '../../utils/session'

const schema = z.object({
  /** `data:image/jpeg;base64,…` — same shape every other camera capture takes. */
  dataUrl: z.string().min(32).max(36_000_000),
})

const DATA_URL_RE = /^data:([\w.+-]+\/[\w.+-]+);base64,([A-Za-z0-9+/=\s]+)$/

/**
 * Read a just-snapped receipt photo and suggest every field: gallons, total,
 * station and address, printed date and time, invoice number and the rest.
 * Nothing is saved — the driver sees these as an editable starting
 * point, not a committed reading (same "suggest, confirm" rule the
 * container/chassis scanner follows).
 */
export default defineEventHandler(async (event) => {
  await requireDriver(event)
  const body = await readValidatedJson(event, schema)

  const match = DATA_URL_RE.exec(body.dataUrl)
  if (!match) throw createError({ statusCode: 422, statusMessage: 'The photo could not be read.' })
  const mimeType = match[1]!.toLowerCase()
  const bytes = Buffer.from(match[2]!, 'base64')
  assertUploadAllowed(mimeType, bytes.byteLength)

  const extraction = await extractFuelReceipt(bytes)
  return { extraction }
})
