import { describe, expect, it } from 'vitest'
import { parseBridgeCrossingFeed } from '../shared/utils/bridge-crossings'

const entry = (facilityId: number, name: string, direction: string, minutes: number, modifier = '') => ({
  facilityId,
  facilityModifier: modifier,
  travelDirection: direction,
  crossingDisplayName: name,
  isCrossingClosed: false,
  routeTravelTime: minutes,
  routeTravelTimeHist: minutes,
  timeStamp: '2026-11-24T08:00:00Z',
})

describe('parseBridgeCrossingFeed', () => {
  it('keeps bridges and drops tunnels', () => {
    const lanes = parseBridgeCrossingFeed([
      entry(1, 'Bayonne Bridge', 'ToNJ', 2),
      entry(2, 'Holland Tunnel', 'ToNJ', 6),
      entry(3, 'Lincoln Tunnel', 'ToNY', 7),
      entry(4, 'Goethals Bridge', 'ToNY', 2),
    ])
    expect(lanes.map(lane => lane.crossingName)).toEqual(['Bayonne Bridge', 'Goethals Bridge'])
  })

  it('keeps only the George Washington Bridge upper level', () => {
    const lanes = parseBridgeCrossingFeed([
      entry(5, 'George Washington Bridge', 'ToNY', 6, 'Upper'),
      entry(5, 'George Washington Bridge', 'ToNY', 9, 'Lower'),
    ])
    expect(lanes.map(lane => lane.travelTimeMinutes)).toEqual([6])
  })
})
