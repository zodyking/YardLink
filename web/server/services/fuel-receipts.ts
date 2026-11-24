import { and, desc, eq, isNull } from 'drizzle-orm'
import {
  type FuelReceiptDetails,
  type FuelReceiptExtraction,
  type FuelReceiptSummary,
  type FuelReceiptWeek,
  groupFuelReceiptsByWeek,
  parseFuelReceiptLines,
  receiptLinesFromBoxes,
} from '#shared/utils/fuel-receipts'
import { fuelReceipts } from '../database/schema'
import type { DbExecutor } from '../utils/db'
import { useDocScanWorker } from './docscan'
import { useOpenOcrWorker } from './openocr'
import { assertUploadAllowed, buildStorageKey, useObjectStorage } from './storage'
import { companyTimezone } from './tasks'

/**
 * Fuel receipt tracking (driver-facing, in the app's More tab).
 *
 * A receipt photo never needs its own OCR engine: the same scene-text reader
 * used for container/chassis plates (./ocr.ts) reads the printed numbers off
 * a receipt just as well — only the parsing that follows is different, and
 * that lives in #shared/utils/fuel-receipts.ts so the same regexes back both
 * the one-off "extract" preview and anything that re-parses stored text later.
 */

const RETURNED_COLUMNS = {
  id: fuelReceipts.id,
  purchasedAt: fuelReceipts.purchasedAt,
  gallons: fuelReceipts.gallons,
  totalAmount: fuelReceipts.totalAmount,
  pricePerGallon: fuelReceipts.pricePerGallon,
  stationName: fuelReceipts.stationName,
  stationAddress: fuelReceipts.stationAddress,
  invoiceNumber: fuelReceipts.invoiceNumber,
  fuelType: fuelReceipts.fuelType,
  cardLast4: fuelReceipts.cardLast4,
  authCode: fuelReceipts.authCode,
  notes: fuelReceipts.notes,
}

/** The shape Drizzle returns for `RETURNED_COLUMNS`: numeric columns come back as strings. */
interface FuelReceiptRow extends FuelReceiptDetails {
  id: string
  purchasedAt: Date
  gallons: string
  totalAmount: string
  pricePerGallon: string | null
  stationName: string | null
  notes: string | null
}

function toSummary(row: FuelReceiptRow): FuelReceiptSummary {
  return {
    id: row.id,
    purchasedAt: row.purchasedAt.toISOString(),
    gallons: Number(row.gallons),
    totalAmount: Number(row.totalAmount),
    pricePerGallon: row.pricePerGallon == null ? null : Number(row.pricePerGallon),
    stationName: row.stationName,
    stationAddress: row.stationAddress,
    invoiceNumber: row.invoiceNumber,
    fuelType: row.fuelType,
    cardLast4: row.cardLast4,
    authCode: row.authCode,
    notes: row.notes,
  }
}

/**
 * Read a receipt photo and suggest every field. Never touches the database —
 * the driver confirms or edits every field before it is saved.
 *
 * The OCR worker is asked for a plain document read (positioned text boxes,
 * no container-plate extras), and the boxes are rebuilt into the receipt's
 * printed lines before parsing, so a label and its value ("TOTAL" and
 * "438.07") are read as the one line they are on paper.
 */
export async function extractFuelReceipt(image: Buffer): Promise<FuelReceiptExtraction> {
  let bytes = image
  const scanned = await useDocScanWorker().restore(image)
  if (scanned.ok && scanned.image) bytes = scanned.image

  const result = await useOpenOcrWorker().recognize(bytes, { document: true })
  return parseFuelReceiptLines(receiptLinesFromBoxes(result.lines))
}

/**
 * Read an already-saved receipt's photo again, so a receipt saved before a
 * field existed (or read badly) can be filled in. Like `extractFuelReceipt`,
 * nothing is saved: the app shows the suggestions for the driver to confirm.
 */
export async function rereadFuelReceipt(
  db: DbExecutor,
  companyId: string,
  driverId: string,
  id: string,
): Promise<FuelReceiptExtraction | null> {
  const file = await loadFuelReceiptFile(db, companyId, driverId, id)
  if (!file) return null
  return extractFuelReceipt(await useObjectStorage().get(file.storageKey))
}

export interface CreateFuelReceiptInput extends Partial<FuelReceiptDetails> {
  companyId: string
  driverId: string
  purchasedAt: Date
  gallons: number
  totalAmount: number
  stationName: string | null
  notes: string | null
  dataUrl: string
  /** The transcript from the earlier `extract` call, if the app made one. OCR never re-runs here. */
  ocrText: string | null
}

const DATA_URL_RE = /^data:([\w.+-]+\/[\w.+-]+);base64,([A-Za-z0-9+/=\s]+)$/

export async function createFuelReceipt(db: DbExecutor, input: CreateFuelReceiptInput): Promise<FuelReceiptSummary> {
  const match = DATA_URL_RE.exec(input.dataUrl)
  if (!match) throw createError({ statusCode: 422, statusMessage: 'The photo could not be read.' })
  const mimeType = match[1]!.toLowerCase()
  const bytes = Buffer.from(match[2]!, 'base64')
  assertUploadAllowed(mimeType, bytes.byteLength)

  const pricePerGallon = input.gallons > 0 ? Math.round((input.totalAmount / input.gallons) * 1000) / 1000 : null

  const stored = await useObjectStorage().put(
    buildStorageKey(input.companyId, 'fuel_receipt', `receipt-${Date.now()}.jpg`),
    bytes,
    mimeType,
  )

  const [row] = await db
    .insert(fuelReceipts)
    .values({
      companyId: input.companyId,
      driverId: input.driverId,
      purchasedAt: input.purchasedAt,
      gallons: String(input.gallons),
      totalAmount: String(input.totalAmount),
      pricePerGallon: pricePerGallon == null ? null : String(pricePerGallon),
      stationName: input.stationName,
      stationAddress: input.stationAddress ?? null,
      invoiceNumber: input.invoiceNumber ?? null,
      fuelType: input.fuelType ?? null,
      cardLast4: input.cardLast4 ?? null,
      authCode: input.authCode ?? null,
      storageKey: stored.key,
      mimeType,
      sizeBytes: stored.size,
      ocrText: input.ocrText,
      notes: input.notes,
    })
    .returning(RETURNED_COLUMNS)

  return toSummary(row!)
}

/** A driver's own receipts, grouped into Monday-start weeks, newest week first. */
export async function listFuelReceiptWeeks(db: DbExecutor, companyId: string, driverId: string): Promise<FuelReceiptWeek[]> {
  const rows = await db
    .select(RETURNED_COLUMNS)
    .from(fuelReceipts)
    .where(and(eq(fuelReceipts.companyId, companyId), eq(fuelReceipts.driverId, driverId), isNull(fuelReceipts.deletedAt)))
    .orderBy(desc(fuelReceipts.purchasedAt))
    .limit(500)

  const timeZone = await companyTimezone(db, companyId)
  return groupFuelReceiptsByWeek(rows.map(toSummary), timeZone)
}

export interface UpdateFuelReceiptInput extends Partial<FuelReceiptDetails> {
  purchasedAt?: Date
  gallons?: number
  totalAmount?: number
  stationName?: string | null
  notes?: string | null
}

export async function updateFuelReceipt(
  db: DbExecutor,
  companyId: string,
  driverId: string,
  id: string,
  patch: UpdateFuelReceiptInput,
): Promise<FuelReceiptSummary | null> {
  const [existing] = await db
    .select({ gallons: fuelReceipts.gallons, totalAmount: fuelReceipts.totalAmount })
    .from(fuelReceipts)
    .where(and(
      eq(fuelReceipts.id, id),
      eq(fuelReceipts.companyId, companyId),
      eq(fuelReceipts.driverId, driverId),
      isNull(fuelReceipts.deletedAt),
    ))
    .limit(1)
  if (!existing) return null

  const gallons = patch.gallons ?? Number(existing.gallons)
  const totalAmount = patch.totalAmount ?? Number(existing.totalAmount)
  const pricePerGallon = gallons > 0 ? Math.round((totalAmount / gallons) * 1000) / 1000 : null

  const next: Partial<typeof fuelReceipts.$inferInsert> = { updatedAt: new Date() }
  if (patch.purchasedAt !== undefined) next.purchasedAt = patch.purchasedAt
  if (patch.gallons !== undefined) next.gallons = String(patch.gallons)
  if (patch.totalAmount !== undefined) next.totalAmount = String(patch.totalAmount)
  if (patch.gallons !== undefined || patch.totalAmount !== undefined) {
    next.pricePerGallon = pricePerGallon == null ? null : String(pricePerGallon)
  }
  if (patch.stationName !== undefined) next.stationName = patch.stationName
  if (patch.stationAddress !== undefined) next.stationAddress = patch.stationAddress
  if (patch.invoiceNumber !== undefined) next.invoiceNumber = patch.invoiceNumber
  if (patch.fuelType !== undefined) next.fuelType = patch.fuelType
  if (patch.cardLast4 !== undefined) next.cardLast4 = patch.cardLast4
  if (patch.authCode !== undefined) next.authCode = patch.authCode
  if (patch.notes !== undefined) next.notes = patch.notes

  const [row] = await db
    .update(fuelReceipts)
    .set(next)
    .where(and(eq(fuelReceipts.id, id), eq(fuelReceipts.companyId, companyId), eq(fuelReceipts.driverId, driverId)))
    .returning(RETURNED_COLUMNS)

  return row ? toSummary(row) : null
}

export async function deleteFuelReceipt(db: DbExecutor, companyId: string, driverId: string, id: string): Promise<boolean> {
  const [row] = await db
    .update(fuelReceipts)
    .set({ deletedAt: new Date() })
    .where(and(
      eq(fuelReceipts.id, id),
      eq(fuelReceipts.companyId, companyId),
      eq(fuelReceipts.driverId, driverId),
      isNull(fuelReceipts.deletedAt),
    ))
    .returning({ id: fuelReceipts.id })
  return Boolean(row)
}

/** Authenticated lookup for the photo-serving route — confirms tenant and driver ownership. */
export async function loadFuelReceiptFile(
  db: DbExecutor,
  companyId: string,
  driverId: string,
  id: string,
): Promise<{ storageKey: string, mimeType: string } | null> {
  const [row] = await db
    .select({ storageKey: fuelReceipts.storageKey, mimeType: fuelReceipts.mimeType })
    .from(fuelReceipts)
    .where(and(
      eq(fuelReceipts.id, id),
      eq(fuelReceipts.companyId, companyId),
      eq(fuelReceipts.driverId, driverId),
      isNull(fuelReceipts.deletedAt),
    ))
    .limit(1)
  return row ?? null
}
