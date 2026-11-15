import { buildConnectLink } from '#shared/utils/connect'
import { qrSvg } from '#shared/utils/qr'
import { ensurePrimaryCompany, formatInviteCode } from '../../utils/company'
import { loadCompanySettings, serverAddressFor } from '../../utils/settings'
import { requireAdmin } from '../../utils/session'

/**
 * The employer connection code dispatchers show to staff. It holds the server
 * address and company name only; the join code is listed beside it for the
 * person to type when they create their account.
 */
export default defineEventHandler(async (event) => {
  await requireAdmin(event)
  const db = useDb()
  const company = await ensurePrimaryCompany(db)
  const settings = await loadCompanySettings(db, { fresh: true })
  const server = serverAddressFor(settings, getRequestURL(event).origin)
  const link = buildConnectLink({ server, name: company.name })

  return {
    server,
    usingConfiguredAddress: Boolean(settings.publicUrl),
    isSecure: server.startsWith('https://'),
    companyName: company.name,
    link,
    qrSvg: qrSvg(link),
    joinCode: formatInviteCode(company.inviteCode),
  }
})
