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

/**
 * What a receipt carries beyond the amounts, each in its own field (never
 * folded into notes). All optional: plenty of receipts leave some out.
 */
export interface FuelReceiptDetails {
  /** The merchant's invoice / receipt / ticket number. */
  invoiceNumber: string | null
  /** Street and city line as printed, e.g. "701 E. Edgar Rd, Linden NJ 07036". */
  stationAddress: string | null
  /** "Diesel", "Unleaded", … as the item line names it. */
  fuelType: string | null
  /** The card's last four digits, from its masked number. */
  cardLast4: string | null
  /** The card authorization / approval code. */
  authCode: string | null
}

export interface FuelReceiptExtraction extends FuelReceiptDetails {
  gallons: number | null
  totalAmount: number | null
  /** Always `totalAmount / gallons` when both are known — never OCR'd separately. */
  pricePerGallon: number | null
  stationName: string | null
  /** The date printed on the receipt, `YYYY-MM-DD`, or null to mean "use the capture date". */
  printedDate: string | null
  /**
   * The time printed with it, 24-hour `HH:mm:ss`, or null. It is wall-clock
   * time where the fuel was bought, so the app reads it in the phone's own
   * time zone (the driver is standing at the pump) rather than the server
   * guessing one.
   */
  printedTime: string | null
  rawText: string
}

export interface FuelReceiptSummary extends FuelReceiptDetails {
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

/** One OCR text box with its position, as the OCR worker returns it. */
export interface ReceiptOcrBox {
  text: string
  box?: unknown
}

interface PlacedBox {
  text: string
  x0: number
  cx: number
  cy: number
  h: number
}

/** (x0, y0, x1, y1) for a quad of points or an `[x, y, w, h]` box — the two shapes the worker emits. */
function boxBounds(box: unknown): [number, number, number, number] | null {
  if (!Array.isArray(box) || box.length < 4) return null
  if (box.slice(0, 4).every(value => typeof value === 'number')) {
    const [x, y, w, h] = box as number[]
    return [x!, y!, x! + w!, y! + h!]
  }
  const xs: number[] = []
  const ys: number[] = []
  for (const point of box) {
    if (Array.isArray(point) && typeof point[0] === 'number' && typeof point[1] === 'number') {
      xs.push(point[0])
      ys.push(point[1])
    }
  }
  if (!xs.length) return null
  return [Math.min(...xs), Math.min(...ys), Math.max(...xs), Math.max(...ys)]
}

/**
 * Rebuild the receipt's printed lines from OCR text boxes. The detector
 * returns one box per word or phrase, in no reliable order, so "TOTAL" and
 * "438.07", or "Invoice #:" and "699374", arrive as unrelated fragments.
 * Boxes that sit on the same printed line are joined left to right with a
 * space, and lines come out top to bottom. A box is matched against the
 * nearest box (left/right) already on a line, so a photo taken slightly
 * crooked still keeps each line together. Boxes without a position are
 * dropped: without one there is no way to know which line they belong to.
 */
export function receiptLinesFromBoxes(boxes: ReceiptOcrBox[]): string[] {
  const placed: PlacedBox[] = []
  for (const entry of boxes) {
    const text = String(entry.text ?? '').replace(/\s+/g, ' ').trim()
    const bounds = boxBounds(entry.box)
    if (!text || !bounds) continue
    const [x0, y0, x1, y1] = bounds
    placed.push({ text, x0, cx: (x0 + x1) / 2, cy: (y0 + y1) / 2, h: Math.max(1, y1 - y0) })
  }

  const rows: PlacedBox[][] = []
  for (const item of [...placed].sort((a, b) => a.cy - b.cy)) {
    const row = rows.find((members) => {
      const nearest = members.reduce((best, member) =>
        Math.abs(member.cx - item.cx) < Math.abs(best.cx - item.cx) ? member : best)
      return Math.abs(nearest.cy - item.cy) <= Math.max(nearest.h, item.h) * 0.5
    })
    if (row) row.push(item)
    else rows.push([item])
  }

  return rows
    .map(members => ({
      cy: members.reduce((sum, member) => sum + member.cy, 0) / members.length,
      text: [...members].sort((a, b) => a.x0 - b.x0).map(member => member.text).join(' '),
    }))
    .sort((a, b) => a.cy - b.cy)
    .map(row => row.text)
}

const GALLON_LINE_RE = /\bGAL(?:LON)?S?\b/i
// "PRICE/GAL" or "$/GAL" names the per-unit price, not the quantity pumped —
// never read a gallon figure off one of those.
const GALLON_EXCLUDE_RE = /PRICE|PER\s*GAL|\$\s*\/\s*GAL/i
// Some pump receipts never spell out "gallons" at all — the item row's
// quantity column carries a bare unit letter instead, e.g. "79.664G". Used
// only when nothing spells out GAL/GALLON(S) anywhere on the receipt.
const GALLON_UNIT_SUFFIX_RE = /(\d{1,3}\.\d{2,3})\s*G\b/i
// A per-unit price ("@ 5.499/ G") can carry the same bare-G suffix as the
// quantity — "@" or "/" right there, or PRICE/PER wording, means "skip it".
const GALLON_UNIT_EXCLUDE_RE = /[@/]|PRICE|PER\b/i
const TOTAL_LINE_RE = /\bTOTAL\b/i
// A line that is clearly tax, discount or a running subtotal rather than the
// amount actually charged.
const NOT_GRAND_TOTAL_RE = /\bSUB\s*TOTAL\b|\bTAX\b|\bDISCOUNT\b|\bSAVINGS\b|\bDUE\b\s*AT\b/i
// Thousands commas are optional ("1,234.56" and "438.07" both match, with
// the comma stripped before the capture is read as a number).
const AMOUNT_RE = /\$?\s*(\d{1,3}(?:,\d{3})*\.\d{2})\b/
// When no line is explicitly labeled "TOTAL" (a poor OCR read can drop the
// word entirely), the line confirming how the card was charged carries the
// same figure and is the next best thing.
const CHARGED_LINE_RE = /\b(?:CREDIT|DEBIT|CHARGED|AMOUNT\s*DUE|USD)\b/i
const GALLON_AMOUNT_RE = /(\d{1,3}\.\d{2,3})/
const DATE_RE = /\b(\d{1,2})[/-](\d{1,2})[/-](\d{2}|\d{4})\b/
// "1:24:03 PM", "13:24", "1:24PM".
const TIME_RE = /\b(\d{1,2}):(\d{2})(?::(\d{2}))?\s*([AP])?\.?M?\.?(?![\w:])/i
// "Invoice #: 699374", "INV#699374", "Invoice No. 1234-5678" — but never
// "INVALID", since \b after INV requires a non-word character right there.
const INVOICE_RE = /\b(?:INVOICE|INV)\b\.?\s*(?:NO\.?|NUMBER|#)?\s*[:#]?\s*([0-9][0-9A-Z-]{2,19})\b/i
// Used only when nothing is labeled as an invoice: truck stops often print
// the same reference as a receipt or ticket number.
const RECEIPT_NUMBER_RE = /\b(?:RECEIPT|TICKET|TKT)\b\.?\s*(?:NO\.?|NUMBER|#)?\s*[:#]?\s*([0-9][0-9A-Z-]{2,19})\b/i
// "Auth #: 965942" / "Approval Code 965942" / "APPR CODE 965942".
const AUTH_CODE_RE = /\b(?:AUTH(?:ORIZATION)?|APPROVAL|APPR)\b\.?\s*(?:CODE|NO\.?|#)?\s*[:#]?\s*([0-9A-Z]{4,12})\b/i
// A masked card number ending in its real last four digits:
// "************7148", "XXXX7148", "****-7148".
const CARD_MASKED_RE = /(?:\*{2,}|X{2,}|•{2,})[\s-]*(\d{4})\b/i
// "Card ending in 7148" / "LAST 4: 7148".
const CARD_ENDING_RE = /\b(?:ENDING(?:\s+IN)?|LAST\s*4)\b\D{0,4}(\d{4})\b/i
// "Linden NJ 07036", "Linden, NJ 07036-1234".
const CITY_STATE_ZIP_RE = /^[A-Za-z][A-Za-z .'-]*?,?\s+[A-Za-z]{2}\.?,?\s+\d{5}(?:-\d{4})?$/
// "701 E. Edgar Rd": a street number, then words.
const STREET_RE = /^\d{1,6}[A-Za-z]?\s+(?=.*[A-Za-z]{2,})[A-Za-z0-9 .#'&-]{3,60}$/
// The fuel named on the item line. Only item lines (those carrying an amount
// or quantity) are searched, so "PLUS"/"SUPER" in a store name never count.
const FUEL_TYPE_RE = /\b(BIO\s*DIESEL|DIESEL|ULSD|UNLEADED|UNL|REGULAR|MID\s*-?\s*GRADE|PLUS|PREMIUM|SUPER|E85|DEF)\b/i
const FUEL_TYPE_NAMES: Record<string, string> = {
  BIODIESEL: 'Biodiesel',
  DIESEL: 'Diesel',
  ULSD: 'Diesel',
  UNLEADED: 'Unleaded',
  UNL: 'Unleaded',
  REGULAR: 'Regular',
  MIDGRADE: 'Midgrade',
  PLUS: 'Plus',
  PREMIUM: 'Premium',
  SUPER: 'Super',
  E85: 'E85',
  DEF: 'DEF',
}
// Boilerplate banner lines printed above (or around) the business name,
// sometimes wrapped in punctuation like "<CUSTOMER COPY>".
const STATION_NAME_SKIP_RE = /^[^A-Za-z0-9]*(?:WELCOME\b|THANK\s*YOU\b|CUSTOMER\s*COPY\b|MERCHANT\s*COPY\b)/i

function roundTo(value: number, decimals: number): number {
  const factor = 10 ** decimals
  return Math.round(value * factor) / factor
}

function parseAmount(text: string): number {
  return Number(text.replace(/,/g, ''))
}

function firstAmountOnOrAfter(lines: string[], index: number, pattern: RegExp): number | null {
  const here = lines[index]?.match(pattern)
  if (here) return parseAmount(here[1]!)
  const next = lines[index + 1]?.match(pattern)
  return next ? parseAmount(next[1]!) : null
}

/**
 * First match of `pattern` across the lines. A label printed with its value
 * on the following line ("Invoice #:" then "699374") is caught by also
 * trying each line joined to the next — only after no single line matched.
 */
function firstMatch(lines: string[], pattern: RegExp): string | null {
  for (const line of lines) {
    const match = pattern.exec(line)
    if (match) return match[1]!
  }
  for (let i = 0; i < lines.length - 1; i++) {
    const match = pattern.exec(`${lines[i]} ${lines[i + 1]}`)
    if (match) return match[1]!
  }
  return null
}

/** A plausible receipt date, `YYYY-MM-DD`: a two-digit year is read as 2000 + yy. */
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
  return date.toISOString().slice(0, 10)
}

/** A printed time of day as 24-hour `HH:mm:ss`, or null. */
function parseReceiptTime(text: string): string | null {
  const match = TIME_RE.exec(text)
  if (!match) return null
  let hour = Number(match[1])
  const minute = Number(match[2])
  const second = match[3] ? Number(match[3]) : 0
  const meridiem = match[4]?.toUpperCase()
  if (minute > 59 || second > 59) return null
  if (meridiem) {
    if (hour < 1 || hour > 12) return null
    if (meridiem === 'P' && hour !== 12) hour += 12
    if (meridiem === 'A' && hour === 12) hour = 0
  }
  else if (hour > 23) {
    return null
  }
  const pad = (value: number) => String(value).padStart(2, '0')
  return `${pad(hour)}:${pad(minute)}:${pad(second)}`
}

function isAddressLine(text: string): boolean {
  return STREET_RE.test(text) || CITY_STATE_ZIP_RE.test(text)
}

/**
 * The street and city lines near the top of the receipt. The city/state/ZIP
 * line is the anchor (it is the easiest to recognize); the street is the line
 * just above it when that line starts with a street number.
 */
function guessStationAddress(lines: string[]): string | null {
  const top = lines.slice(0, 12)
  const cityIndex = top.findIndex(line => CITY_STATE_ZIP_RE.test(line))
  if (cityIndex >= 0) {
    const street = cityIndex > 0 && STREET_RE.test(top[cityIndex - 1]!) ? top[cityIndex - 1] : null
    return [street, top[cityIndex]].filter(Boolean).join(', ').slice(0, 200)
  }
  const street = top.find(line => STREET_RE.test(line) && !DATE_RE.test(line) && !AMOUNT_RE.test(line))
  return street ? street.slice(0, 200) : null
}

/** First line that reads like a business name rather than a number, a date, an address, or a boilerplate banner. */
function guessStationName(lines: string[]): string | null {
  for (const text of lines.slice(0, 6)) {
    if (text.length < 3) continue
    if (!/[A-Za-z]{3,}/.test(text)) continue
    if (DATE_RE.test(text) || AMOUNT_RE.test(text)) continue
    if (STATION_NAME_SKIP_RE.test(text)) continue
    if (isAddressLine(text)) continue
    return text.slice(0, 60)
  }
  return null
}

/** The fuel named on the first item line (a line that also carries a quantity or an amount). */
function guessFuelType(lines: string[]): string | null {
  for (const line of lines) {
    if (!/\d\.\d{2}/.test(line)) continue
    const match = FUEL_TYPE_RE.exec(line)
    if (!match) continue
    const key = match[1]!.toUpperCase().replace(/[\s-]/g, '')
    return FUEL_TYPE_NAMES[key] ?? null
  }
  return null
}

/**
 * Read gallons, the amount charged, the station and its address, the
 * printed date and time, and the receipt's reference numbers off a diesel
 * receipt's printed lines (see `receiptLinesFromBoxes`). Anything not found
 * comes back null rather than guessed, since a wrong number here is worse
 * than a blank field the driver fills in themselves.
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
  // Nothing spelled out GAL/GALLON(S) anywhere — fall back to a bare "G"
  // unit suffix on the quantity itself (see GALLON_UNIT_SUFFIX_RE above).
  if (gallons == null) {
    for (const line of clean) {
      if (GALLON_UNIT_EXCLUDE_RE.test(line)) continue
      const match = GALLON_UNIT_SUFFIX_RE.exec(line)
      if (!match) continue
      const value = Number(match[1])
      if (value > 0 && value < 300) {
        gallons = value
        break
      }
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
  // No line was actually labeled "TOTAL" — the card-charge confirmation
  // line ("CREDIT $438.07", "USD$438.07") carries the same figure and is
  // printed on nearly every pump receipt even when "TOTAL" itself doesn't
  // OCR cleanly.
  if (totalAmount == null) {
    for (let i = clean.length - 1; i >= 0; i--) {
      const line = clean[i]!
      if (!CHARGED_LINE_RE.test(line)) continue
      const value = firstAmountOnOrAfter(clean, i, AMOUNT_RE)
      if (value != null && value > 0 && value < 2000) {
        totalAmount = value
        break
      }
    }
  }

  // The time is read off the date's own line first (that pairing is the
  // printed timestamp); any other time on the receipt is a fallback.
  const dateIndex = clean.findIndex(line => parseReceiptDate(line) !== null)
  const printedDate = dateIndex >= 0 ? parseReceiptDate(clean[dateIndex]!) : null
  const printedTime = (dateIndex >= 0 ? parseReceiptTime(clean[dateIndex]!) : null)
    ?? clean.map(parseReceiptTime).find((time): time is string => time !== null)
    ?? null

  return {
    gallons,
    totalAmount,
    pricePerGallon: gallons && totalAmount ? roundTo(totalAmount / gallons, 3) : null,
    stationName: guessStationName(clean),
    stationAddress: guessStationAddress(clean),
    printedDate,
    printedTime,
    fuelType: guessFuelType(clean),
    invoiceNumber: firstMatch(clean, INVOICE_RE) ?? firstMatch(clean, RECEIPT_NUMBER_RE),
    cardLast4: firstMatch(clean, CARD_MASKED_RE) ?? firstMatch(clean, CARD_ENDING_RE),
    authCode: firstMatch(clean, AUTH_CODE_RE),
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
