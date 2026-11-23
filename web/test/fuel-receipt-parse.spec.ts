import { describe, expect, it } from 'vitest'
import { parseFuelReceiptLines } from '../shared/utils/fuel-receipts'

describe('fuel receipt parse', () => {
  it('reads gallons, total, station, invoice number, and extras off a real receipt', () => {
    const result = parseFuelReceiptLines([
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
    ])

    expect(result.gallons).toBe(79.664)
    expect(result.totalAmount).toBe(438.07)
    expect(result.stationName).toBe('Fuel One Linden 701')
    expect(result.invoiceNumber).toBe('699374')
    expect(result.suggestedNotes).toBe('Auth #965942 · Trans #1018109 · Card ••7148')
  })

  it('falls back to the gallons figure when nothing spells out GAL/GALLON', () => {
    const result = parseFuelReceiptLines(['DIESEL 79.664G 438.07'])
    expect(result.gallons).toBe(79.664)
  })

  it('skips a "WELCOME TO" banner line when guessing the station name', () => {
    const result = parseFuelReceiptLines(['WELCOME TO', 'Pilot Travel Center', '10.0 GAL', 'TOTAL 35.00'])
    expect(result.stationName).toBe('Pilot Travel Center')
  })

  it('falls back to the card-charge line when nothing is labeled TOTAL', () => {
    const result = parseFuelReceiptLines(['10.0 GAL', 'CREDIT $35.00'])
    expect(result.totalAmount).toBe(35.0)
  })

  it('reads a comma-grouped total', () => {
    const result = parseFuelReceiptLines(['TOTAL $1,234.56'])
    expect(result.totalAmount).toBe(1234.56)
  })

  it('never mistakes "INVALID" for an invoice number', () => {
    const result = parseFuelReceiptLines(['Card INVALID, try again'])
    expect(result.invoiceNumber).toBeNull()
  })

  it('returns nulls, not guesses, when a receipt carries none of this', () => {
    const result = parseFuelReceiptLines(['Thanks for stopping by'])
    expect(result.gallons).toBeNull()
    expect(result.totalAmount).toBeNull()
    expect(result.invoiceNumber).toBeNull()
    expect(result.suggestedNotes).toBeNull()
  })
})
