import { addIsoDays, calendarDateInZone } from './sms-task'

/**
 * Fuel receipt domain model and OCR parsing.
 *
 * A driver snaps a photo of a diesel receipt; the server reads it with the
 * same scene-text OCR engine used for container/chassis plates (./ocr-parse.ts
 * is the plate-specific sibling of this file), then this module turns the
 * raw transcript into a best guess at the gallons and the total paid. The
 * guess is never saved on its own — the driver always sees it in an editable
 * form first, the same "suggest, don't silently accept" rule the equipment
 * scanner follows.
 */

export interface FuelReceiptExtraction {
  gallons: number | null
  totalAmount: number | null
  /** Always `totalAmount / gallons` when both are known — never OCR'd separately. */
  pricePerGallon: number | null
  stationName: string | null
  /** ISO date the receipt itself appears to carry, or null to mean "use the capture time". */
  purchasedAt: string | null
  rawText: string
}

export interface FuelReceiptSummary {
  id: string
  purchasedAt: string
  gallons: number
  totalAmount: number
  pricePerGallon: number | null
  stationName: string | null
  notes: string | null
}

/** One calendar week's receipts, Monday through Sunday. */
export interface FuelReceiptWeek {
  /** Monday of the week, `YYYY-MM-DD`. */
  weekStart: string
  weekEnd: string
  receipts: FuelReceiptSummary[]
  totalGallons: number
  totalAmount: number
  averagePricePerGallon: number | null
}

const GALLON_LINE_RE = /\bGAL(?:LON)?S?\b/i
// "PRICE/GAL" or "$/GAL" names the per-unit price, not the quantity pumped —
// never read a gallon figure off one of those.
const GALLON_EXCLUDE_RE = /PRICE|PER\s*GAL|\$\s*\/\s*GAL/i
const TOTAL_LINE_RE = /\bTOTAL\b/i
// A line that is clearly tax, discount or a running subtotal rather than the
// amount actually charged.
const NOT_GRAND_TOTAL_RE = /\bSUB\s*TOTAL\b|\bTAX\b|\bDISCOUNT\b|\bSAVINGS\b|\bDUE\b\s*AT\b/i
const AMOUNT_RE = /\$?\s*(\d{1,4}\.\d{2})\b/
const GALLON_AMOUNT_RE = /(\d{1,3}\.\d{2,3})/
const DATE_RE = /\b(\d{1,2})[/-](\d{1,2})[/-](\d{2}|\d{4})\b/

function roundTo(value: number, decimals: number): number {
  const factor = 10 ** decimals
  return Math.round(value * factor) / factor
}

function firstAmountOnOrAfter(lines: string[], index: number, pattern: RegExp): number | null {
  const here = lines[index]?.match(pattern)
  if (here) return Number(here[1])
  const next = lines[index + 1]?.match(pattern)
  return next ? Number(next[1]) : null
}

/** A plausible receipt date: a two-digit year is read as 2000 + yy. */
function parseReceiptDate(text: string): string | null {
  const match = DATE_RE.exec(text)
  if (!match) return null
  const month = Number(match[1])
  const day = Number(match[2])
  const year = match[3]!.length === 2 ? 2000 + Number(match[3]) : Number(match[3])
  if (month < 1 || month > 12 || day < 1 || day > 31) return null
  const date = new Date(Date.UTC(year, month - 1, day))
  if (date.getUTCFullYear() !== year || date.getUTCMonth() !== month - 1 || date.getUTCDate() !== day) return null
  // A receipt is never from the future and is never implausibly old.
  const now = new Date()
  if (date.getTime() > now.getTime() + 24 * 60 * 60 * 1000) return null
  if (now.getTime() - date.getTime() > 400 * 24 * 60 * 60 * 1000) return null
  return date.toISOString()
}

/** First line that reads like a business name rather than a number or a date. */
function guessStationName(lines: string[]): string | null {
  for (const line of lines.slice(0, 4)) {
    const text = line.replace(/\s+/g, ' ').trim()
    if (text.length < 3) continue
    if (!/[A-Za-z]{3,}/.test(text)) continue
    if (DATE_RE.test(text) || AMOUNT_RE.test(text)) continue
    return text.slice(0, 60)
  }
  return null
}

/**
 * Read gallons, the amount charged, and (best-effort) the station name and
 * date off a diesel receipt's OCR transcript. Anything not found comes back
 * null rather than guessed, since a wrong number here is worse than a blank
 * field the driver fills in themselves.
 */
export function parseFuelReceiptLines(lines: string[]): FuelReceiptExtraction {
  const clean = lines.map(line => line.replace(/\s+/g, ' ').trim()).filter(Boolean)

  let gallons: number | null = null
  for (let i = 0; i < clean.length; i++) {
    if (!GALLON_LINE_RE.test(clean[i]!) || GALLON_EXCLUDE_RE.test(clean[i]!)) continue
    const value = firstAmountOnOrAfter(clean, i, GALLON_AMOUNT_RE)
    if (value != null && value > 0 && value < 300) {
      gallons = value
      break
    }
  }

  // The grand total is usually the last qualifying "TOTAL" line on the
  // receipt (subtotal and tax come first), so scan in reverse.
  let totalAmount: number | null = null
  for (let i = clean.length - 1; i >= 0; i--) {
    const line = clean[i]!
    if (!TOTAL_LINE_RE.test(line) || NOT_GRAND_TOTAL_RE.test(line)) continue
    const value = firstAmountOnOrAfter(clean, i, AMOUNT_RE)
    if (value != null && value > 0 && value < 2000) {
      totalAmount = value
      break
    }
  }

  const pricePerGallon = gallons && totalAmount ? roundTo(totalAmount / gallons, 3) : null
  const stationName = guessStationName(clean)
  const purchasedAt = clean.map(parseReceiptDate).find((d): d is string => d !== null) ?? null

  return {
    gallons,
    totalAmount,
    pricePerGallon,
    stationName,
    purchasedAt,
    rawText: clean.join(' | ').slice(0, 2000),
  }
}

/** Monday of the calendar week (in `timeZone`) that `date` falls in. */
export function fuelReceiptWeekStart(date: Date, timeZone: string): string {
  const iso = calendarDateInZone(date, timeZone)
  const [year, month, day] = iso.split('-').map(Number)
  const dow = new Date(Date.UTC(year!, month! - 1, day!)).getUTCDay() // 0 = Sunday
  const sinceMonday = dow === 0 ? 6 : dow - 1
  return addIsoDays(iso, -sinceMonday)
}

/** Group receipts into Monday-start weeks, newest week first. */
export function groupFuelReceiptsByWeek(
  receipts: FuelReceiptSummary[],
  timeZone: string,
): FuelReceiptWeek[] {
  const byWeek = new Map<string, FuelReceiptSummary[]>()
  for (const receipt of receipts) {
    const weekStart = fuelReceiptWeekStart(new Date(receipt.purchasedAt), timeZone)
    const bucket = byWeek.get(weekStart) ?? []
    bucket.push(receipt)
    byWeek.set(weekStart, bucket)
  }

  return [...byWeek.entries()]
    .sort((a, b) => (a[0] < b[0] ? 1 : -1))
    .map(([weekStart, weekReceipts]) => {
      const sorted = [...weekReceipts].sort((a, b) => (a.purchasedAt < b.purchasedAt ? 1 : -1))
      const totalGallons = roundTo(sorted.reduce((sum, r) => sum + r.gallons, 0), 3)
      const totalAmount = roundTo(sorted.reduce((sum, r) => sum + r.totalAmount, 0), 2)
      return {
        weekStart,
        weekEnd: addIsoDays(weekStart, 6),
        receipts: sorted,
        totalGallons,
        totalAmount,
        averagePricePerGallon: totalGallons > 0 ? roundTo(totalAmount / totalGallons, 3) : null,
      }
    })
}
