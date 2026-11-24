import { describe, expect, it } from 'vitest'
import { parseFuelReceiptLines, receiptLinesFromBoxes } from '../shared/utils/fuel-receipts'

const REAL_RECEIPT = [
  'WELCOME TO',
  '****************',
  'Fuel One Linden 701',
  '701 E. Edgar Rd',
  'Linden NJ 07036',
  '<CUSTOMER COPY>',
  'Description Qty Amount',
  'DIESEL CA #20 79.664G 438.07',
  'FULL @ 5.499/ G',
  'Subtotal 438.07',
  'TOTAL 438.07',
  'CREDIT $ 438.07',
  'SALE Receipt',
  'USD$438.07',
  'Acct/Card #: ************7148',
  'Entry: Chip Read',
  'AppName: US DEBIT',
  'AuthNet: VISA',
  'MODE: Issuer',
  'AID: A0000000980840',
  'Auth #: 965942',
  'Resp Code: 000',
  'Stan: 0328502388',
  'Invoice #: 699374',
  'Shift #: 1',
  'Store # ****************',
  'PIN Bypassed',
  'CUSTOMER COPY',
  'ST#FUEL ONE DR#1 TRAN#1018109',
  'CSH: 1 11/23/26 1:24:03 PM',
]

/** A word box as the OCR worker returns it: text plus a four-point quad. */
const box = (text: string, x: number, y: number) => ({
  text,
  box: [[x, y], [x + text.length * 14, y], [x + text.length * 14, y + 24], [x, y + 24]],
})

describe('fuel receipt parse', () => {
  it('reads every field off a real receipt', () => {
    const result = parseFuelReceiptLines(REAL_RECEIPT)

    expect(result.gallons).toBe(79.664)
    expect(result.totalAmount).toBe(438.07)
    expect(result.pricePerGallon).toBe(5.499)
    expect(result.stationName).toBe('Fuel One Linden 701')
    expect(result.stationAddress).toBe('701 E. Edgar Rd, Linden NJ 07036')
    expect(result.fuelType).toBe('Diesel')
    expect(result.invoiceNumber).toBe('699374')
    expect(result.cardLast4).toBe('7148')
    expect(result.authCode).toBe('965942')
    expect(result.printedDate).toBe('2026-11-23')
    expect(result.printedTime).toBe('13:24:03')
  })

  it('falls back to the gallons figure when nothing spells out GAL/GALLON', () => {
    expect(parseFuelReceiptLines(['DIESEL 79.664G 438.07']).gallons).toBe(79.664)
  })

  it('skips banner lines, wrapped or not, when guessing the station name', () => {
    const result = parseFuelReceiptLines(['<CUSTOMER COPY>', 'WELCOME TO', 'Pilot Travel Center', '10.0 GAL', 'TOTAL 35.00'])
    expect(result.stationName).toBe('Pilot Travel Center')
  })

  it('falls back to the card-charge line when nothing is labeled TOTAL', () => {
    expect(parseFuelReceiptLines(['10.0 GAL', 'CREDIT $35.00']).totalAmount).toBe(35.0)
  })

  it('reads a comma-grouped total', () => {
    expect(parseFuelReceiptLines(['TOTAL $1,234.56']).totalAmount).toBe(1234.56)
  })

  it('reads a label whose value printed on the next line', () => {
    const result = parseFuelReceiptLines(['Invoice #:', '699374', 'Card ending in 4421'])
    expect(result.invoiceNumber).toBe('699374')
    expect(result.cardLast4).toBe('4421')
  })

  it('uses a ticket number when nothing is labeled invoice', () => {
    expect(parseFuelReceiptLines(['Ticket # 55821']).invoiceNumber).toBe('55821')
  })

  it('never mistakes INVALID for an invoice or AuthNet for an auth code', () => {
    const result = parseFuelReceiptLines(['Card INVALID, try again', 'AuthNet: VISA'])
    expect(result.invoiceNumber).toBeNull()
    expect(result.authCode).toBeNull()
  })

  it('returns nulls, not guesses, when a receipt carries none of this', () => {
    const result = parseFuelReceiptLines(['Thanks for stopping by'])
    expect(result.gallons).toBeNull()
    expect(result.totalAmount).toBeNull()
    expect(result.invoiceNumber).toBeNull()
    expect(result.stationAddress).toBeNull()
    expect(result.printedDate).toBeNull()
    expect(result.printedTime).toBeNull()
  })
})

describe('receiptLinesFromBoxes', () => {
  it('rebuilds printed lines from word boxes in any order', () => {
    const boxes = [
      box('438.07', 600, 403),
      box('Invoice #:', 140, 700),
      box('Fuel One', 300, 30),
      box('TOTAL', 250, 400),
      box('699374', 330, 701),
      box('Linden 701', 520, 31),
    ]
    expect(receiptLinesFromBoxes(boxes)).toEqual(['Fuel One Linden 701', 'TOTAL 438.07', 'Invoice #: 699374'])
  })

  it('keeps a slightly crooked line together', () => {
    const boxes = [box('DIESEL', 100, 300), box('79.664G', 400, 308), box('438.07', 700, 316)]
    expect(receiptLinesFromBoxes(boxes)).toEqual(['DIESEL 79.664G 438.07'])
  })

  it('drops text that has no position', () => {
    expect(receiptLinesFromBoxes([{ text: 'GLUED', box: null }, box('TOTAL', 0, 0)])).toEqual(['TOTAL'])
  })
})
