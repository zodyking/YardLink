import { describe, expect, it } from 'vitest'
import { formatLocationDirectoryCsv } from '../shared/utils/location-csv'
import { locationImportTemplate, parseCsv, parseLocationImport } from '../shared/utils/location-import'

describe('location import', () => {
  it('reads quoted cells with commas, quotes and line breaks', () => {
    expect(parseCsv('a,"b, c","say ""hi""","two\nlines"\r\n1,2,3,4\r\n'))
      .toEqual([['a', 'b, c', 'say "hi"', 'two\nlines'], ['1', '2', '3', '4']])
  })

  it('reads back a file written by the location export', () => {
    const csv = formatLocationDirectoryCsv([{
      name: 'Acme Foods, Inc.',
      type: 'CUSTOMER',
      addressLine1: '2500 Commerce Blvd',
      city: 'Orlando',
      state: 'FL',
      postalCode: '32809',
      mainPhone: '+14075550142',
      appointmentRequired: true,
      status: 'ACTIVE',
      capacity: 12,
    }])
    const parsed = parseLocationImport(csv)
    expect(parsed.fileError).toBeNull()
    expect(parsed.errors).toEqual([])
    expect(parsed.rows).toHaveLength(1)
    expect(parsed.rows[0]).toMatchObject({
      line: 2,
      name: 'Acme Foods, Inc.',
      type: 'CUSTOMER',
      city: 'Orlando',
      appointmentRequired: true,
      status: 'ACTIVE',
      capacity: 12,
    })
    expect(parsed.rows[0]!.mainPhone).toBe('(407) 555-0142')
  })

  it('imports its own template', () => {
    const parsed = parseLocationImport(locationImportTemplate())
    expect(parsed.errors).toEqual([])
    expect(parsed.warnings).toEqual([])
    expect(parsed.rows.map(row => row.type)).toEqual(['COMPANY_YARD', 'CUSTOMER'])
    expect(parsed.rows[0]).toMatchObject({ latitude: 30.401, longitude: -81.565 })
  })

  it('needs Name and Type columns', () => {
    expect(parseLocationImport('Place,City\nYard,Miami\n').fileError).toContain('Name column')
    expect(parseLocationImport('').fileError).toBe('This file is empty.')
  })

  it('lists rows it cannot import and keeps the rest', () => {
    const parsed = parseLocationImport([
      'Name,Type,Main phone,Capacity',
      'North Yard,Company Yard,555,lots',
      ',Customer Location,,',
      'Dock 9,Warehouse,,',
      'north yard,Customer Location,,',
    ].join('\n'))
    expect(parsed.rows.map(row => row.name)).toEqual(['North Yard'])
    expect(parsed.rows[0]).toMatchObject({ mainPhone: null, capacity: null })
    expect(parsed.warnings.map(item => item.line)).toEqual([2, 2])
    expect(parsed.errors.map(item => item.line)).toEqual([3, 4, 5])
  })
})
