import { listFuelReceiptWeeks } from '../../services/fuel-receipts'
import { requireDriver } from '../../utils/session'

/** The signed-in driver's own receipts, grouped Monday-start by week, newest week first. */
export default defineEventHandler(async (event) => {
  const auth = await requireDriver(event)
  const weeks = await listFuelReceiptWeeks(useDb(), auth.companyId, auth.driverId)
  return { weeks }
})
