import { z } from 'zod'
import { createFuelReceipt } from '../../services/fuel-receipts'
import { fuelReceiptDetailsShape, normalizeFuelReceiptDetails } from '../../utils/fuel-receipt-details'
import { requireDriver } from '../../utils/session'

const schema = z.object({
  dataUrl: z.string().min(32).max(36_000_000),
  purchasedAt: z.string().datetime().optional(),
  gallons: z.number().positive().max(300),
  totalAmount: z.number().positive().max(2000),
  stationName: z.string().trim().max(120).nullish(),
  ...fuelReceiptDetailsShape,
  notes: z.string().trim().max(500).nullish(),
  /** The transcript from an earlier `/extract` call, if the app made one. */
  ocrText: z.string().max(2000).nullish(),
})

/**
 * Save a confirmed (or hand-edited) diesel receipt: the photo, the amounts
 * the driver confirmed, and whatever the scan read, for the record.
 */
export default defineEventHandler(async (event) => {
  const auth = await requireDriver(event)
  const body = await readValidatedJson(event, schema)
  const db = useDb()

  const receipt = await createFuelReceipt(db, {
    companyId: auth.companyId,
    driverId: auth.driverId,
    purchasedAt: body.purchasedAt ? new Date(body.purchasedAt) : new Date(),
    gallons: body.gallons,
    totalAmount: body.totalAmount,
    stationName: body.stationName?.trim() || null,
    ...normalizeFuelReceiptDetails(body),
    notes: body.notes?.trim() || null,
    dataUrl: body.dataUrl,
    ocrText: body.ocrText ?? null,
  })

  return { receipt }
})
