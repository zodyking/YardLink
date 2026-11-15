import { describe, expect, it } from 'vitest'
import { checkDatabaseUrl, describeDatabase } from '../shared/utils/database-url'

describe('database connection string', () => {
  it('accepts a full PostgreSQL address and summarises it without the password', () => {
    const check = checkDatabaseUrl('  postgresql://yard:s3cret@db.example.com:6543/yardlink?sslmode=require ')
    expect(check.ok).toBe(true)
    if (!check.ok) return
    expect(check.url).toBe('postgresql://yard:s3cret@db.example.com:6543/yardlink?sslmode=require')
    expect(check.summary).toEqual({ host: 'db.example.com', port: 6543, database: 'yardlink', user: 'yard' })
    expect(describeDatabase(check.summary)).toBe('db.example.com:6543 / yardlink')
    expect(describeDatabase(check.summary)).not.toContain('s3cret')
  })

  it('defaults the port and accepts the short scheme', () => {
    const check = checkDatabaseUrl('postgres://yard:pw@10.0.0.5/yard')
    expect(check.ok && check.summary.port).toBe(5432)
  })

  it('explains what is missing', () => {
    expect(checkDatabaseUrl('')).toMatchObject({ ok: false })
    expect(checkDatabaseUrl('mysql://u:p@h/db')).toMatchObject({ ok: false })
    expect(checkDatabaseUrl('postgresql://yard:pw@db.example.com')).toMatchObject({ ok: false })
    expect(checkDatabaseUrl('postgresql://db.example.com/yard')).toMatchObject({ ok: false })
  })
})
