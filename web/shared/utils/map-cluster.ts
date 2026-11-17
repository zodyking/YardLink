/**
 * Grouping for the board map. Sites that would sit on top of each other at the
 * current zoom collapse into one numbered circle; zooming in pulls them apart.
 */
export interface ClusterSite {
  id: string
  latitude: number
  longitude: number
  occupancy: number
}

export interface SiteCluster<T extends ClusterSite = ClusterSite> {
  /** Stable for the same members, so a redraw does not flicker. */
  key: string
  latitude: number
  longitude: number
  sites: T[]
  /** Containers on site across the group. */
  occupancy: number
}

/** Closer than this on screen, sites share a circle. */
export const CLUSTER_RADIUS_PX = 64
/** From this zoom (a few city blocks across) every site stands alone. */
export const CLUSTER_MAX_ZOOM = 15

const TILE_PX = 256

/** Web Mercator position of a point, in pixels at a zoom. */
function project(latitude: number, longitude: number, zoom: number): { x: number, y: number } {
  const scale = TILE_PX * 2 ** zoom
  const sin = Math.min(Math.max(Math.sin((latitude * Math.PI) / 180), -0.9999), 0.9999)
  return {
    x: ((longitude + 180) / 360) * scale,
    y: (0.5 - Math.log((1 + sin) / (1 - sin)) / (4 * Math.PI)) * scale,
  }
}

export function clusterSites<T extends ClusterSite>(
  sites: T[],
  zoom: number,
  options: { radiusPx?: number, keepApart?: string | null } = {},
): SiteCluster<T>[] {
  const radius = options.radiusPx ?? CLUSTER_RADIUS_PX
  const groups: Array<{ members: T[], x: number, y: number }> = []
  const alone = zoom >= CLUSTER_MAX_ZOOM

  for (const site of sites) {
    const at = project(site.latitude, site.longitude, zoom)
    const standsAlone = alone || site.id === options.keepApart
    const near = standsAlone
      ? undefined
      : groups.find(group =>
          !(group.members.length === 1 && group.members[0]!.id === options.keepApart)
          && Math.hypot(group.x - at.x, group.y - at.y) <= radius)

    if (!near) {
      groups.push({ members: [site], x: at.x, y: at.y })
      continue
    }
    const n = near.members.length
    near.x = (near.x * n + at.x) / (n + 1)
    near.y = (near.y * n + at.y) / (n + 1)
    near.members.push(site)
  }

  return groups.map((group) => {
    const count = group.members.length
    const latitude = group.members.reduce((sum, site) => sum + site.latitude, 0) / count
    const longitude = group.members.reduce((sum, site) => sum + site.longitude, 0) / count
    return {
      key: group.members.map(site => site.id).sort().join('|'),
      latitude,
      longitude,
      sites: group.members,
      occupancy: group.members.reduce((sum, site) => sum + site.occupancy, 0),
    }
  })
}
