import { z } from 'zod'
import type { FuelReceiptDetails } from '#shared/utils/fuel-receipts'

/** A trimmed optional text field: blank becomes null, absent stays absent. */
const optionalText = (max: number) => z.string().trim().max(max).nullish()

/**
 * The receipt detail fields (invoice number, address, …) as the create and
 * update routes accept them. Kept in one place so both routes validate them
 * the same way.
 */
export const fuelReceiptDetailsShape = {
  invoiceNumber: optionalText(40),
  stationAddress: optionalText(200),
  fuelType: optionalText(40),
  cardLast4: z.string().trim().regex(/^\d{4}$/, 'Card last four must be 4 digits.').or(z.literal('')).nullish(),
  authCode: optionalText(20),
}

type DetailsInput = { [K in keyof FuelReceiptDetails]?: string | null }

/**
 * Normalize the details a route received: blank text becomes null, and a
 * field the request left out stays undefined so an update leaves it alone.
 */
export function normalizeFuelReceiptDetails(input: DetailsInput): Partial<FuelReceiptDetails> {
  const out: Partial<FuelReceiptDetails> = {}
  for (const key of ['invoiceNumber', 'stationAddress', 'fuelType', 'cardLast4', 'authCode'] as const) {
    const value = input[key]
    if (value === undefined) continue
    out[key] = value?.trim() || null
  }
  return out
}
