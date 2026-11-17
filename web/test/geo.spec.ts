import { describe, expect, it } from 'vitest'
import { countContainersByType } from '../shared/utils/domain'
import {
  autoSiteRadius,
  bboxAround,
  bearingDeg,
  containerCorners,
  haversineMeters,
  isUnitedStatesCountry,
  longestEdgeBearing,
  normalizeHeading,
  parseCoord,
  parsePin,
  pointInPolygon,
  polygonFromBbox,
  polygonFromRing,
  snapHeadingToStreet,
  isPlausibleYardFence,
} from '../shared/utils/geo'

describe('containerCorners', () => {
  it('places the long axis north when heading is 0', () => {
    const corners = containerCorners(26.1, -80.2, 12, 2.4, 0)
    const lats = corners.map(c => c[0])
    const lngs = corners.map(c => c[1])
    expect(Math.max(...lats) - Math.min(...lats)).toBeGreaterThan(Math.max(...lngs) - Math.min(...lngs))
  })

  it('rotates the long axis east when heading is 90', () => {
    const corners = containerCorners(26.1, -80.2, 12, 2.4, 90)
    const lats = corners.map(c => c[0])
    const lngs = corners.map(c => c[1])
    expect(Math.max(...lngs) - Math.min(...lngs)).toBeGreaterThan(Math.max(...lats) - Math.min(...lats))
  })
})

describe('parsePin', () => {
  it('accepts numeric strings and rejects 0,0 and blanks', () => {
    expect(parseCoord('26.1')).toBeCloseTo(26.1)
    expect(parsePin('26.115', '-80.172')).toEqual({ latitude: 26.115, longitude: -80.172 })
    expect(parsePin(0, 0)).toBeNull()
    expect(parsePin('', '-80.1')).toBeNull()
    expect(parsePin(null, -80.1)).toBeNull()
  })
})

describe('isPlausibleYardFence', () => {
  it('accepts a terminal-sized box and rejects a continental view', () => {
    expect(isPlausibleYardFence(polygonFromBbox(bboxAround(26.1, -80.2, 80)))).toBe(true)
    expect(isPlausibleYardFence(polygonFromBbox({
      west: -104,
      south: 31,
      east: -90,
      north: 43,
    }))).toBe(false)
  })
})

describe('polygonFromRing', () => {
  it('closes an open triangle and rejects a two-point line', () => {
    const polygon = polygonFromRing([
      [-80.2, 26.1],
      [-80.19, 26.1],
      [-80.195, 26.11],
    ])
    expect(polygon?.type).toBe('Polygon')
    expect(polygon?.coordinates[0]).toHaveLength(4)
    expect(polygon?.coordinates[0]![0]).toEqual(polygon?.coordinates[0]!.at(-1))
    expect(polygonFromRing([[-80.2, 26.1], [-80.19, 26.1]])).toBeNull()
  })
})

describe('pointInPolygon', () => {
  it('accepts a point inside a bbox ring and rejects one outside', () => {
    const polygon = polygonFromBbox(bboxAround(26.1, -80.2, 80))
    expect(pointInPolygon(26.1, -80.2, polygon)).toBe(true)
    expect(pointInPolygon(26.2, -80.2, polygon)).toBe(false)
  })
})

describe('snapHeadingToStreet', () => {
  it('keeps the closer of the street heading and its reverse', () => {
    expect(snapHeadingToStreet(10, 0)).toBe(0)
    expect(snapHeadingToStreet(170, 0)).toBe(180)
  })
})

describe('longestEdgeBearing', () => {
  it('returns the east-west edge of a wide rectangle', () => {
    const polygon = polygonFromBbox({ west: -80.21, south: 26.10, east: -80.19, north: 26.101 })
    const heading = longestEdgeBearing(polygon)
    expect(heading).not.toBeNull()
    const aligned = Math.min(headingDelta(heading!, 90), headingDelta(heading!, 270))
    expect(aligned).toBeLessThan(1)
  })
})

describe('haversineMeters / bearingDeg', () => {
  it('measures a short north-south segment', () => {
    const metres = haversineMeters(26.10, -80.20, 26.101, -80.20)
    expect(metres).toBeGreaterThan(100)
    expect(metres).toBeLessThan(120)
    expect(normalizeHeading(bearingDeg(26.10, -80.20, 26.101, -80.20))).toBeCloseTo(0, 0)
  })
})

describe('countContainersByType', () => {
  it('counts every brand including zeros', () => {
    const counts = countContainersByType([
      { containerType: 'KING_OCEAN' },
      { containerType: 'KING_OCEAN' },
      { containerType: 'CMA' },
    ])
    expect(counts).toEqual({ KING_OCEAN: 2, TROPICAL: 0, CMA: 1, ZIM: 0 })
  })
})

describe('isUnitedStatesCountry', () => {
  it('accepts US codes and names', () => {
    expect(isUnitedStatesCountry('US')).toBe(true)
    expect(isUnitedStatesCountry('us')).toBe(true)
    expect(isUnitedStatesCountry('USA')).toBe(true)
    expect(isUnitedStatesCountry('United States')).toBe(true)
    expect(isUnitedStatesCountry('United States of America')).toBe(true)
  })

  it('rejects other countries', () => {
    expect(isUnitedStatesCountry('NL')).toBe(false)
    expect(isUnitedStatesCountry('CA')).toBe(false)
    expect(isUnitedStatesCountry('Vietnam')).toBe(false)
    expect(isUnitedStatesCountry('')).toBe(false)
    expect(isUnitedStatesCountry(null)).toBe(false)
  })
})

function headingDelta(a: number, b: number) {
  const delta = Math.abs(normalizeHeading(a) - normalizeHeading(b))
  return Math.min(delta, 360 - delta)
}

describe('autoSiteRadius', () => {
  it('uses the usual size for each kind of site when there is no outline', () => {
    expect(autoSiteRadius('MARINE_TERMINAL')).toBe(600)
    expect(autoSiteRadius('RAIL_TERMINAL')).toBe(500)
    expect(autoSiteRadius('COMPANY_YARD')).toBe(220)
    expect(autoSiteRadius('CUSTOMER')).toBe(140)
  })

  it('reaches the far corner of an outline, a little past it', () => {
    const outline = bboxAround(40.7, -74.1, 400)
    const radius = autoSiteRadius('COMPANY_YARD', outline)
    expect(radius).toBeGreaterThan(400 * Math.SQRT2)
    expect(radius).toBeLessThan(400 * Math.SQRT2 * 1.3)
  })

  it('never shrinks below half the usual size for a tiny outline', () => {
    expect(autoSiteRadius('MARINE_TERMINAL', bboxAround(40.7, -74.1, 5))).toBe(300)
  })

  it('stays inside what the app allows', () => {
    expect(autoSiteRadius('CUSTOMER', bboxAround(40.7, -74.1, 20_000))).toBe(2000)
  })
})
