import { CONNECT_API_VERSION } from '#shared/utils/connect'
import { loadPrimaryCompany } from '../utils/company'

/**
 * Public. The iPhone app calls this right after scanning the employer code to
 * confirm the address really is a Yard Link server before showing sign-in.
 * It names the company and nothing else.
 */
export default defineEventHandler(async (event) => {
  setResponseHeader(event, 'Cache-Control', 'no-store')
  const company = await loadPrimaryCompany(useDb())
  return {
    app: 'yardlink',
    apiVersion: CONNECT_API_VERSION,
    ready: Boolean(company),
    companyName: company?.name ?? null,
  }
})
