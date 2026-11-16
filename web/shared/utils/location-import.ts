import { LOCATION_TYPE_LABELS, LOCATION_TYPES } from './domain'
import type { LocationType } from './domain'
import { LOCATION_CSV_HEADERS, csvCell } from './location-csv'
import { isValidPhone } from './phone'

/**
 * Reading a location spreadsheet (CSV) for import.
 *
 * The columns are the ones the location export writes, so a file exported
 * from one Yard Link server imports into another unchanged. Only Name and
 * Type are required; Latitude and Longitude are accepted as extra columns.
 * Shared so the dispatcher sees the same result in the preview as the server
 * produces when the file is imported.
 */

export const LOCATION_IMPORT_MAX_ROWS = 2000

export type LocationImportStatus = 'ACTIVE' | 'PENDING_APPROVAL' | 'ARCHIVED'

export interface LocationImportRow {
  /** Line in the spreadsheet, counting the header as line 1. */
  line: number
  name: string
  type: LocationType
  locationCode: string | null
  addressLine1: string | null
  addressLine2: string | null
  city: string | null
  state: string | null
  postalCode: string | null
  mainPhone: string | null
  contactName: string | null
  contactPhone: string | null
  hours: string | null
  appointmentRequired: boolean
  status: LocationImportStatus
  gateInstructions: string | null
  driverNotes: string | null
  shipcsxTerminal: string | null
  capacity: number | null
  latitude: number | null
  longitude: number | null
}

export interface LocationImportIssue {
  line: number
  name: string
  message: string
}

export interface LocationImportParse {
  rows: LocationImportRow[]
  /** Lines that cannot be imported, with the reason. */
  errors: LocationImportIssue[]
  /** Lines that are imported with something left out. */
  warnings: LocationImportIssue[]
  /** A problem with the file as a whole; nothing can be imported. */
  fileError: string | null
}

/** Split CSV text into rows of cells: quotes, doubled quotes, commas and line breaks inside quotes. */
export function parseCsv(text: string): string[][] {
  const source = text.replace(/^﻿/, '')
  const rows: string[][] = []
  let row: string[] = []
  let cell = ''
  let quoted = false

  for (let i = 0; i < source.length; i++) {
    const char = source[i]!
    if (quoted) {
      if (char === '"') {
        if (source[i + 1] === '"') {
          cell += '"'
          i++
        }
        else {
          quoted = false
        }
      }
      else {
        cell += char
      }
      continue
    }
    if (char === '"' && cell === '') {
      quoted = true
    }
    else if (char === ',') {
      row.push(cell)
      cell = ''
    }
    else if (char === '\n' || char === '\r') {
      if (char === '\r' && source[i + 1] === '\n') i++
      row.push(cell)
      rows.push(row)
      row = []
      cell = ''
    }
    else {
      cell += char
    }
  }
  if (cell !== '' || row.length) {
    row.push(cell)
    rows.push(row)
  }
  return rows.filter(cells => cells.some(value => value.trim() !== ''))
}

function key(value: string): string {
  return value.toLowerCase().replace(/[^a-z0-9]/g, '')
}

/** Header as written in a spreadsheet → field. Includes common other spellings. */
const COLUMN_FIELDS: Record<string, string> = {
  name: 'name',
  locationname: 'name',
  type: 'type',
  locationtype: 'type',
  code: 'locationCode',
  locationcode: 'locationCode',
  address: 'addressLine1',
  address1: 'addressLine1',
  addressline1: 'addressLine1',
  street: 'addressLine1',
  address2: 'addressLine2',
  addressline2: 'addressLine2',
  city: 'city',
  state: 'state',
  postalcode: 'postalCode',
  zip: 'postalCode',
  zipcode: 'postalCode',
  country: 'country',
  mainphone: 'mainPhone',
  phone: 'mainPhone',
  contactname: 'contactName',
  contact: 'contactName',
  contactphone: 'contactPhone',
  hours: 'hours',
  appointment: 'appointmentRequired',
  appointmentrequired: 'appointmentRequired',
  status: 'status',
  gateinstructions: 'gateInstructions',
  drivernotes: 'driverNotes',
  notes: 'driverNotes',
  shipcsxterminal: 'shipcsxTerminal',
  capacity: 'capacity',
  latitude: 'latitude',
  lat: 'latitude',
  longitude: 'longitude',
  lng: 'longitude',
  lon: 'longitude',
}

const TYPE_BY_KEY: Record<string, LocationType> = (() => {
  const map: Record<string, LocationType> = {
    yard: 'COMPANY_YARD',
    customer: 'CUSTOMER',
    port: 'MARINE_TERMINAL',
    terminal: 'MARINE_TERMINAL',
    rail: 'RAIL_TERMINAL',
    railterminal: 'RAIL_TERMINAL',
  }
  for (const type of LOCATION_TYPES) {
    map[key(type)] = type
    map[key(LOCATION_TYPE_LABELS[type])] = type
  }
  return map
})()

const STATUS_BY_KEY: Record<string, LocationImportStatus> = {
  active: 'ACTIVE',
  pendingapproval: 'PENDING_APPROVAL',
  pending: 'PENDING_APPROVAL',
  archived: 'ARCHIVED',
}

function textOrNull(value: string | undefined, max: number): string | null {
  const trimmed = (value ?? '').trim()
  return trimmed ? trimmed.slice(0, max) : null
}

function coordinate(value: string | undefined, limit: number): number | null {
  const trimmed = (value ?? '').trim()
  if (!trimmed) return null
  const number = Number(trimmed)
  return Number.isFinite(number) && Math.abs(number) <= limit ? number : null
}

/** Read a location spreadsheet into rows ready to save, with every problem listed by line. */
export function parseLocationImport(text: string): LocationImportParse {
  const empty: LocationImportParse = { rows: [], errors: [], warnings: [], fileError: null }
  const table = parseCsv(text)
  if (!table.length) return { ...empty, fileError: 'This file is empty.' }

  const fields = table[0]!.map(header => COLUMN_FIELDS[key(header)] ?? '')
  if (!fields.includes('name') || !fields.includes('type')) {
    return { ...empty, fileError: 'The first row must have a Name column and a Type column. Download the template to see the layout.' }
  }
  if (table.length - 1 > LOCATION_IMPORT_MAX_ROWS) {
    return { ...empty, fileError: `A file can hold up to ${LOCATION_IMPORT_MAX_ROWS} locations. Split this one and import it in parts.` }
  }

  const result: LocationImportParse = { ...empty, rows: [], errors: [], warnings: [] }
  const seen = new Set<string>()

  table.slice(1).forEach((cells, index) => {
    const line = index + 2
    const raw: Record<string, string> = {}
    fields.forEach((field, column) => {
      if (field) raw[field] = cells[column] ?? ''
    })

    const name = (raw.name ?? '').trim().slice(0, 160)
    if (!name) {
      result.errors.push({ line, name: '', message: 'No name.' })
      return
    }
    const type = TYPE_BY_KEY[key(raw.type ?? '')]
    if (!type) {
      const allowed = LOCATION_TYPES.map(value => LOCATION_TYPE_LABELS[value]).join(', ')
      result.errors.push({ line, name, message: `Type "${(raw.type ?? '').trim() || 'empty'}" is not one of: ${allowed}.` })
      return
    }
    if (seen.has(name.toLowerCase())) {
      result.errors.push({ line, name, message: 'This name appears more than once in the file.' })
      return
    }
    seen.add(name.toLowerCase())

    const phone = (field: 'mainPhone' | 'contactPhone', label: string) => {
      const value = (raw[field] ?? '').trim()
      if (!value) return null
      if (isValidPhone(value)) return value
      result.warnings.push({ line, name, message: `${label} "${value}" is not a 10-digit US number and is left empty.` })
      return null
    }

    const capacityText = (raw.capacity ?? '').trim()
    const capacity = /^\d{1,6}$/.test(capacityText) ? Number(capacityText) : null
    if (capacityText && capacity === null) {
      result.warnings.push({ line, name, message: `Capacity "${capacityText}" is not a whole number and is left empty.` })
    }

    const latitude = coordinate(raw.latitude, 90)
    const longitude = coordinate(raw.longitude, 180)
    const hasPin = latitude !== null && longitude !== null

    result.rows.push({
      line,
      name,
      type,
      locationCode: textOrNull(raw.locationCode, 40),
      addressLine1: textOrNull(raw.addressLine1, 200),
      addressLine2: textOrNull(raw.addressLine2, 200),
      city: textOrNull(raw.city, 120),
      state: textOrNull(raw.state, 60),
      postalCode: textOrNull(raw.postalCode, 20),
      mainPhone: phone('mainPhone', 'Main phone'),
      contactName: textOrNull(raw.contactName, 120),
      contactPhone: phone('contactPhone', 'Contact phone'),
      hours: textOrNull(raw.hours, 200),
      appointmentRequired: /^(yes|y|true|1|required)$/i.test((raw.appointmentRequired ?? '').trim()),
      status: STATUS_BY_KEY[key(raw.status ?? '')] ?? 'ACTIVE',
      gateInstructions: textOrNull(raw.gateInstructions, 2000),
      driverNotes: textOrNull(raw.driverNotes, 2000),
      shipcsxTerminal: textOrNull(raw.shipcsxTerminal, 80),
      capacity,
      latitude: hasPin ? latitude : null,
      longitude: hasPin ? longitude : null,
    })
  })

  return result
}

/** A starter file: the header row and one example of each kind of place. */
export function locationImportTemplate(): string {
  const headers = [...LOCATION_CSV_HEADERS, 'Latitude', 'Longitude']
  const examples: string[][] = [
    ['Main Yard', 'Company Yard', 'YARD1', '100 Port Road', '', 'Jacksonville', 'FL', '32218', 'US', '(904) 555-0100', 'Sam Ortiz', '(904) 555-0101', 'Mon to Fri 6am to 6pm', 'No', 'Active', 'Use gate 2', '', '', '120', '30.4010', '-81.5650'],
    ['Acme Foods', 'Customer Location', '', '2500 Commerce Blvd', 'Dock 4', 'Orlando', 'FL', '32809', 'US', '(407) 555-0142', '', '', '', 'Yes', 'Active', '', 'Check in at the guard shack', '', '', '', ''],
  ]
  const lines = [headers, ...examples].map(row => row.map(csvCell).join(','))
  return `﻿${lines.join('\r\n')}\r\n`
}
