import { and, eq, sql } from 'drizzle-orm'
import { companyMemberships } from '../database/schema'
import type { DbExecutor } from './db'
import { loadPrimaryCompany } from './company'

/**
 * A fresh install has no company or no dispatcher who can sign in. Until both
 * exist, the web app shows the setup wizard instead of the sign-in page.
 */
export async function needsSetup(db: DbExecutor): Promise<boolean> {
  const company = await loadPrimaryCompany(db)
  if (!company) return true
  const [admins] = await db
    .select({ value: sql<number>`count(*)::int` })
    .from(companyMemberships)
    .where(and(eq(companyMemberships.companyId, company.id), eq(companyMemberships.role, 'ADMIN')))
  return (admins?.value ?? 0) === 0
}
