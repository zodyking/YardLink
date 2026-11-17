import { describe, expect, it } from 'vitest'
import { CLUSTER_MAX_ZOOM, clusterSites } from '../shared/utils/map-cluster'

const site = (id: string, latitude: number, longitude: number, occupancy = 0) => ({ id, latitude, longitude, occupancy })

// Two terminals a few hundred metres apart in Elizabeth, one in Philadelphia.
const sites = [
  site('apm', 40.6700, -74.1500, 4),
  site('depot', 40.6720, -74.1470, 2),
  site('philly', 39.9526, -75.1652, 7),
]

describe('clusterSites', () => {
  it('groups sites that overlap when zoomed out and counts their containers', () => {
    const groups = clusterSites(sites, 9)
    expect(groups).toHaveLength(2)
    const near = groups.find(group => group.sites.length === 2)!
    expect(near.occupancy).toBe(6)
    expect(near.latitude).toBeCloseTo(40.671, 3)
  })

  it('pulls the group apart as the map zooms in', () => {
    expect(clusterSites(sites, 9)).toHaveLength(2)
    expect(clusterSites(sites, 16)).toHaveLength(3)
  })

  it('never groups once zoomed in close', () => {
    const twins = [site('a', 40.67, -74.15), site('b', 40.67, -74.15)]
    expect(clusterSites(twins, CLUSTER_MAX_ZOOM)).toHaveLength(2)
    expect(clusterSites(twins, CLUSTER_MAX_ZOOM - 1)).toHaveLength(1)
  })

  it('keeps the selected site on its own', () => {
    const groups = clusterSites(sites, 9, { keepApart: 'apm' })
    expect(groups).toHaveLength(3)
    expect(groups.find(group => group.sites.some(item => item.id === 'apm'))!.sites).toHaveLength(1)
  })

  it('names a group the same way however its members are ordered', () => {
    const a = clusterSites([sites[0]!, sites[1]!], 9)[0]!
    const b = clusterSites([sites[1]!, sites[0]!], 9)[0]!
    expect(a.key).toBe(b.key)
  })

  it('answers nothing for no sites', () => {
    expect(clusterSites([], 9)).toEqual([])
  })
})
