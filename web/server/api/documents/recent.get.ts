import { driverDocumentGroups } from '../../services/document-scope'
import { requireDriver } from '../../utils/session'

/**
 * The equipment a driver is working or has just dropped off, each with the
 * files that followed it through its service cycle.
 */
export default defineEventHandler(async (event) => {
  const auth = await requireDriver(event)
  const groups = await driverDocumentGroups(useDb(), auth.companyId, auth.driverId)
  return { groups }
})
