import { eq } from 'drizzle-orm'
import { z } from 'zod'
import { SHIPCSX_TERMINALS } from '#shared/utils/csx-lookup'
import { companies } from '../../database/schema'
import { formatInviteCode, generateInviteCode } from '../../utils/company'
import { cleanPublicUrl, saveCompanySettings } from '../../utils/settings'
import { requireAdmin } from '../../utils/session'

function isTimezone(value: string): boolean {
  try {
    new Intl.DateTimeFormat('en-US', { timeZone: value })
    return true
  }
  catch {
    return false
  }
}

const schema = z.object({
  name: z.string().trim().min(1, 'Enter the company name.').max(120).optional(),
  legalName: z.string().trim().max(160).optional(),
  usdotNumber: z.string().trim().max(20).optional(),
  timezone: z.string().trim().max(60).refine(isTimezone, 'Choose a timezone.').optional(),
  publicUrl: z.string().trim().max(300).optional(),
  shipcsxDefaultTerminal: z.string().trim().max(80).optional(),
  approveNewAccounts: z.boolean().optional(),
  bridgeCrossingTimesEnabled: z.boolean().optional(),
  timeCardOfficePhone: z.string().trim().max(40).optional(),
  timeCardDispatchPhone: z.string().trim().max(40).optional(),
  timeCardReportingLocation: z.string().trim().max(160).optional(),
  /** Replace the join code; people who already have accounts are unaffected. */
  newJoinCode: z.literal(true).optional(),
})

/** Every employer-facing setting is changed here — nothing needs a redeploy. */
export default defineEventHandler(async (event) => {
  const auth = await requireAdmin(event)
  const body = await readValidatedJson(event, schema)
  const db = useDb()

  if (body.shipcsxDefaultTerminal && !(SHIPCSX_TERMINALS as readonly string[]).includes(body.shipcsxDefaultTerminal)) {
    throw createError({ statusCode: 422, statusMessage: 'Choose a CSX location from the list.' })
  }
  if (body.publicUrl && !cleanPublicUrl(body.publicUrl)) {
    throw createError({ statusCode: 422, statusMessage: 'Enter the server address like https://yard.example.com' })
  }

  const profile: Partial<typeof companies.$inferInsert> = {}
  if (body.name !== undefined) profile.name = body.name
  if (body.legalName !== undefined) profile.legalName = body.legalName || null
  if (body.usdotNumber !== undefined) profile.usdotNumber = body.usdotNumber || null
  if (body.timezone !== undefined) profile.timezone = body.timezone
  if (body.newJoinCode) profile.inviteCode = generateInviteCode()

  if (Object.keys(profile).length) {
    await db.update(companies).set({ ...profile, updatedAt: new Date() }).where(eq(companies.id, auth.companyId))
  }

  const settings = await saveCompanySettings(db, auth.companyId, {
    publicUrl: body.publicUrl,
    shipcsxDefaultTerminal: body.shipcsxDefaultTerminal,
    approveNewAccounts: body.approveNewAccounts,
    bridgeCrossingTimesEnabled: body.bridgeCrossingTimesEnabled,
    timeCardOfficePhone: body.timeCardOfficePhone,
    timeCardDispatchPhone: body.timeCardDispatchPhone,
    timeCardReportingLocation: body.timeCardReportingLocation,
  })

  const [company] = await db.select().from(companies).where(eq(companies.id, auth.companyId)).limit(1)
  return {
    ok: true,
    company: company
      ? {
          name: company.name,
          legalName: company.legalName,
          usdotNumber: company.usdotNumber,
          timezone: company.timezone,
          inviteCode: formatInviteCode(company.inviteCode),
        }
      : null,
    settings,
  }
})
