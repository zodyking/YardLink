import { z } from 'zod'
import { updateFuelReceipt } from '../../services/fuel-receipts'
import { requireDriver } from '../../utils/session'

const schema = z.object({
  purchasedAt: z.string().datetime().optional(),
  gallons: z.number().positive().max(300).optional(),
  totalAmount: z.number().positive().max(2000).optional(),
  stationName: z.string().trim().max(120).nullish(),
  notes: z.string().trim().max(500).nullish(),
}).refine(body => Object.values(body).some(value => value !== undefined), {
  message: 'Nothing to update.',
})

/** Fix a misread amount or station after the fact. The photo itself never changes. */
export default defineEventHandler(async (event) => {
  const auth = await requireDriver(event)
  const id = getRouterParam(event, 'id')
  if (!id) throw createError({ statusCode: 400, statusMessage: 'Receipt id is required.' })

  const body = await readValidatedJson(event, schema)
  const receipt = await updateFuelReceipt(useDb(), auth.companyId, auth.driverId, id, {
    purchasedAt: body.purchasedAt ? new Date(body.purchasedAt) : undefined,
    gallons: body.gallons,
    totalAmount: body.totalAmount,
    stationName: body.stationName === undefined ? undefined : (body.stationName?.trim() || null),
    notes: body.notes === undefined ? undefined : (body.notes?.trim() || null),
  })
  if (!receipt) throw createError({ statusCode: 404, statusMessage: 'Receipt not found.' })

  return { receipt }
})
