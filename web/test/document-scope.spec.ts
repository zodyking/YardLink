import { describe, expect, it } from 'vitest'
import { containerWindow, tripWindow, withinWindow } from '../shared/utils/document-scope'

const at = (iso: string) => new Date(iso)
const trip = (over: Partial<Parameters<typeof tripWindow>[0]> = {}) => ({
  createdAt: at('2026-11-10T08:00:00Z'),
  pickedUpAt: at('2026-11-10T09:00:00Z') as Date | null,
  droppedOffAt: null as Date | null,
  completedAt: null as Date | null,
  status: 'IN_TRANSIT',
  ...over,
})

describe('document windows', () => {
  it('keeps a live trip open-ended from the pickup', () => {
    const window = tripWindow(trip())
    expect(window.from).toEqual(at('2026-11-10T09:00:00Z'))
    expect(window.to).toBeNull()
    expect(withinWindow(at('2026-11-12T00:00:00Z'), window)).toBe(true)
    expect(withinWindow(at('2026-11-10T08:30:00Z'), window)).toBe(false)
  })

  it('closes a trip at its drop-off', () => {
    const window = tripWindow(trip({ status: 'DROPPED_OFF', droppedOffAt: at('2026-11-10T15:00:00Z') }))
    expect(withinWindow(at('2026-11-10T14:00:00Z'), window)).toBe(true)
    expect(withinWindow(at('2026-11-10T16:00:00Z'), window)).toBe(false)
  })

  it('follows the container through the whole service cycle', () => {
    const cycle = { startedAt: at('2026-11-08T07:00:00Z'), completedAt: null }
    const window = containerWindow(trip({ status: 'DROPPED_OFF', droppedOffAt: at('2026-11-10T15:00:00Z') }), cycle)
    expect(withinWindow(at('2026-11-09T10:00:00Z'), window)).toBe(true)
    expect(withinWindow(at('2026-11-11T10:00:00Z'), window)).toBe(true)
  })

  it('leaves a finished cycle behind when the container is reused', () => {
    const cycle = { startedAt: at('2026-11-01T07:00:00Z'), completedAt: at('2026-11-05T12:00:00Z') }
    const window = containerWindow(trip(), cycle)
    expect(withinWindow(at('2026-11-10T10:00:00Z'), window)).toBe(false)
  })

  it('falls back to the trip when there is no cycle', () => {
    expect(containerWindow(trip(), null)).toEqual(tripWindow(trip()))
  })
})
