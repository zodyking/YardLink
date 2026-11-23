import type { TimeCardHeader, TimeCardStop } from './time-card'
import { TIME_CARD_STOP_MAX } from './time-card'

/** Letter page, matching the printed Sensible Logistics short-haul card. */
export const TIME_CARD_PAGE_WIDTH = 612
export const TIME_CARD_PAGE_HEIGHT = 792

export type TimeCardDrawOp = {
  x: number
  /** Distance from the top of the page, same system as the template PDF. */
  topY: number
  size: number
  text: string
  bold?: boolean
}

/**
 * Employer-supplied values that replace the predecessor company's real
 * name, phone numbers, and "normal reporting location" baked into the
 * template — see `TIME_CARD_BRANDING_COVERS`. All blank unless the employer
 * has set them in Settings; a blank value is simply left off the printed
 * card rather than guessed.
 */
export interface TimeCardBranding {
  companyName: string
  officePhone: string
  dispatchPhone: string
  reportingLocation: string
}

/** One row of the page-2 location directory. */
export interface TimeCardDirectoryEntry {
  name: string
  address: string
  phone: string
}

export interface TimeCardCoverRect {
  x: number
  /** Distance from the top of the page, same system as the template PDF. */
  topY: number
  width: number
  height: number
}

const HEADER: Record<string, { x: number, topY: number, size?: number, max?: number }> = {
  driverName: { x: 94, topY: 103, max: 36 },
  date: { x: 346, topY: 103, max: 28 },
  truckUnit: { x: 98, topY: 118.2, max: 34 },
  trailerNumber: { x: 356, topY: 118.2, size: 8, max: 46 },
  cdl: { x: 97, topY: 133.5, max: 34 },
  employeeId: { x: 372, topY: 133.5, max: 28 },
  dispatcher: { x: 88, topY: 148.7, max: 36 },
  routeCustomer: { x: 388, topY: 148.7, max: 28 },
  startOdometer: { x: 104, topY: 164, max: 28 },
  endOdometer: { x: 378, topY: 164, max: 28 },
}

const TOTALS: Record<string, { x: number, topY: number, max?: number }> = {
  reportForDuty: { x: 41, topY: 665.8, max: 12 },
  releasedFromDuty: { x: 175, topY: 665.8, max: 12 },
  totalOnDutyHours: { x: 309, topY: 665.8, max: 12 },
  // Clear of the "(first-time / intermittent use)" note printed in that cell.
  preceding7DayHours: { x: 524, topY: 665.8, max: 6 },
}

const SIGN = {
  signedName: { x: 128, topY: 731.2, max: 28 },
  signedDate: { x: 325, topY: 731.2, max: 10 },
}

/** The driver signs the printed card by hand, so only the shift totals are filled. */
export const TIME_CARD_FILL_FOOTER = true

/**
 * Regions on page 1 that name the predecessor company ("Sensible Logistics
 * Solutions LLC") in the baked-in template image — covered in white and
 * redrawn with this employer's own branding. Measured directly off the
 * template with `pdftotext -bbox`; margins are generous enough to fully
 * clear the baked text without touching a neighboring label.
 */
export const TIME_CARD_BRANDING_COVERS: TimeCardCoverRect[] = [
  { x: 120, topY: 14, width: 340, height: 38 }, // company name
  { x: 464, topY: 28, width: 84, height: 12 }, // office phone
  { x: 464, topY: 54, width: 84, height: 14 }, // dispatch phone
  { x: 185, topY: 171, width: 365, height: 13 }, // normal reporting location
]

/** Page-2 location directory: columns and paging for the replacement page. */
export const TIME_CARD_DIRECTORY_ROWS_PER_PAGE = 36
export const TIME_CARD_DIRECTORY_ROW_H = 16.5
export const TIME_CARD_DIRECTORY_TOP = 112
export const TIME_CARD_DIRECTORY_COLS = { name: 40, address: 210, phone: 470 }

const ROW0_TOP = 220
const ROW_H = 15.85
const COL = {
  timeIn: 64,
  timeOut: 132,
  location: 198,
  activity: 406,
}

/** pdf-lib origin is bottom-left. Sit the baseline just above a form underline. */
export function timeCardPdfY(topY: number): number {
  return TIME_CARD_PAGE_HEIGHT - topY + 2
}

/**
 * Bottom-left y for a rectangle whose top edge sits `topY` from the page
 * top and is `height` tall — the exact conversion, unlike `timeCardPdfY`,
 * which nudges a text baseline and would throw a cover rectangle's edges
 * off by that same couple of points.
 */
export function timeCardPdfRectY(topY: number, height: number): number {
  return TIME_CARD_PAGE_HEIGHT - topY - height
}

export function clipTimeCardText(value: string, maxChars: number): string {
  const text = value.replace(/\s+/g, ' ').trim()
  if (text.length <= maxChars) return text
  if (maxChars <= 3) return text.slice(0, Math.max(0, maxChars))
  return `${text.slice(0, maxChars - 3)}...`
}

export function timeCardRowTopY(index: number): number {
  return ROW0_TOP + (index + 1) * ROW_H - 4
}

function op(x: number, topY: number, text: string, max: number, size = 9, bold = false): TimeCardDrawOp | null {
  const clipped = clipTimeCardText(text, max)
  if (!clipped) return null
  return { x, topY, size, text: clipped, bold }
}

/** Overlay positions for the employer branding that replaces the baked-in regions on page 1. */
export function timeCardBrandingPlan(branding: TimeCardBranding): TimeCardDrawOp[] {
  const ops: TimeCardDrawOp[] = []
  const name = op(126, 40, branding.companyName, 40, 15, true)
  if (name) ops.push(name)
  const officePhone = op(468, 36, branding.officePhone, 18, 9)
  if (officePhone) ops.push(officePhone)
  const dispatchPhone = op(468, 63, branding.dispatchPhone, 18, 9)
  if (dispatchPhone) ops.push(dispatchPhone)
  const reportingLocation = op(190, 179, branding.reportingLocation, 78, 9)
  if (reportingLocation) ops.push(reportingLocation)
  return ops
}

/** Overlay positions for every filled field on page 1 of the printed card. */
export function timeCardDrawPlan(header: TimeCardHeader, stops: TimeCardStop[]): TimeCardDrawOp[] {
  const ops: TimeCardDrawOp[] = []

  for (const [field, slot] of Object.entries(HEADER)) {
    const value = header[field as keyof TimeCardHeader] ?? ''
    const drawn = op(slot.x, slot.topY, value, slot.max ?? 32, slot.size ?? 9)
    if (drawn) ops.push(drawn)
  }

  stops.slice(0, TIME_CARD_STOP_MAX).forEach((stop, index) => {
    const topY = timeCardRowTopY(index)
    const timeIn = op(COL.timeIn, topY, stop.timeIn, 5, 8)
    const timeOut = op(COL.timeOut, topY, stop.timeOut, 5, 8)
    const location = op(COL.location, topY, stop.location, 52, 8)
    const activity = op(COL.activity, topY, stop.activity, 38, 8)
    for (const drawn of [timeIn, timeOut, location, activity]) {
      if (drawn) ops.push(drawn)
    }
  })

  if (TIME_CARD_FILL_FOOTER) {
    for (const [field, slot] of Object.entries(TOTALS)) {
      const value = header[field as keyof TimeCardHeader] ?? ''
      const drawn = op(slot.x, slot.topY, value, slot.max ?? 12, 9)
      if (drawn) ops.push(drawn)
    }
    const signedName = op(SIGN.signedName.x, SIGN.signedName.topY, header.signedName, SIGN.signedName.max, 9)
    const signedDate = op(SIGN.signedDate.x, SIGN.signedDate.topY, header.signedDate, SIGN.signedDate.max, 9)
    if (signedName) ops.push(signedName)
    if (signedDate) ops.push(signedDate)
  }

  return ops
}
