import { getDriverTimeCard, loadTimeCardDirectory } from '../../../services/time-cards'
import { fillTimeCardPdf } from '../../../services/time-card-pdf'
import { loadCompanySettings } from '../../../utils/settings'
import { requireDriver } from '../../../utils/session'
import { timeCardPdfFileName } from '#shared/utils/time-card'
import type { TimeCardBranding } from '#shared/utils/time-card-layout'

/** Exact two-page short-haul PDF, filled from the day's card. */
export default defineEventHandler(async (event) => {
  const auth = await requireDriver(event)
  const workDate = getRouterParam(event, 'date')
  if (!workDate) {
    throw createError({ statusCode: 400, statusMessage: 'Work date is required.' })
  }

  try {
    const db = useDb()
    const [card, settings, directory] = await Promise.all([
      getDriverTimeCard(db, auth, workDate),
      loadCompanySettings(db),
      loadTimeCardDirectory(db, auth.companyId),
    ])
    const branding: TimeCardBranding = {
      companyName: auth.companyName,
      officePhone: settings.timeCardOfficePhone,
      dispatchPhone: settings.timeCardDispatchPhone,
      reportingLocation: settings.timeCardReportingLocation,
    }
    const bytes = await fillTimeCardPdf(card.header, card.stops, branding, directory)
    const fileName = timeCardPdfFileName(card.workDate)
    const download = getQuery(event).download === '1'
    const body = Buffer.from(bytes)

    setHeader(event, 'Content-Type', 'application/pdf')
    setHeader(event, 'Content-Disposition', `${download ? 'attachment' : 'inline'}; filename="${fileName}"`)
    setHeader(event, 'Cache-Control', 'private, max-age=30')
    return body
  }
  catch (err) {
    if (err && typeof err === 'object' && 'statusCode' in err) throw err
    const message = err instanceof Error ? err.message : 'Could not build the time card PDF.'
    throw createError({
      statusCode: 500,
      statusMessage: message.slice(0, 180) || 'Could not build the time card PDF.',
    })
  }
})
