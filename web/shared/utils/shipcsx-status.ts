import type { CsxLookupTab } from './csx-lookup'

export const CSX_TAB_LABELS: Record<CsxLookupTab, string> = {
  NOTIFIED: 'Notified',
  ENROUTE: 'En route',
  IN_GATE: 'In-gate',
  OTHERS: 'Other',
  NOT_FOUND: 'Not on CSX',
}

export interface ShipcsxStatusInput {
  inGateReadiness?: string | null
  resultTab?: string | null
  waybillDate?: string | null
  gateWindow?: string | null
  loadEmpty?: string | null
  terminalName?: string | null
  error?: string | null
  checkedAt?: Date | string | null
}

/** Short status for the ShipCSX panel. Never show raw enum underscores. */
export function shipcsxStatusLabel(snapshot: ShipcsxStatusInput | null | undefined): string {
  if (!snapshot) return 'Not checked'
  if (snapshot.error && !snapshot.inGateReadiness) return 'Couldn\'t check'
  if (snapshot.inGateReadiness?.trim()) return snapshot.inGateReadiness.trim()
  const tab = snapshot.resultTab?.replace(/-/g, '_') as CsxLookupTab | undefined
  if (tab && CSX_TAB_LABELS[tab]) return CSX_TAB_LABELS[tab]
  return 'Checked'
}

export function shipcsxMetaLine(snapshot: ShipcsxStatusInput | null | undefined): string {
  if (!snapshot) return ''
  return [
    snapshot.terminalName,
    snapshot.loadEmpty,
    snapshot.waybillDate && `Waybill ${snapshot.waybillDate}`,
    snapshot.gateWindow,
  ]
    .filter(Boolean)
    .join(' · ')
}
