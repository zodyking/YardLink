/**
 * Port Authority of NY & NJ live bridge/tunnel crossing-time feed.
 * Undocumented but public; reverse-engineered from the live response.
 */
export const BRIDGE_CROSSING_FEED_URL = 'https://www.panynj.gov/bin/portauthority/crossingtimesapi.json'

/** One poll every 5 minutes gives ~288 points per lane over 24 hours — plenty for the history graph without hammering the feed. */
export const BRIDGE_CROSSING_POLL_INTERVAL_MS = 5 * 60 * 1000

/** Kept a bit past a day so the 24-hour graph never runs short at its edge. */
export const BRIDGE_CROSSING_RETENTION_MS = 30 * 60 * 60 * 1000

/** Minutes of change needed before a trend counts as worsening/improving rather than steady — single-poll noise isn't a trend. */
export const BRIDGE_CROSSING_TREND_THRESHOLD_MINUTES = 2

/** How far back to look for the "worsening or improving" comparison. */
export const BRIDGE_CROSSING_TREND_WINDOW_MS = 30 * 60 * 1000

/**
 * The feed's own direction vocabulary ("toward NY" / "toward NJ"), kept
 * verbatim as the stored and wire value — translating it to another scheme
 * would just be a second place for the two to drift apart.
 */
export const BRIDGE_CROSSING_DIRECTIONS = ['ToNY', 'ToNJ'] as const
export type BridgeCrossingDirection = (typeof BRIDGE_CROSSING_DIRECTIONS)[number]

export type BridgeCrossingTrend = 'IMPROVING' | 'WORSENING' | 'STEADY'

/** One row of the raw feed array. Extra fields (speed, colors, route ids) exist but are unused. */
export interface BridgeCrossingRawEntry {
  facilityId?: unknown
  facilityModifier?: unknown
  travelDirection?: unknown
  crossingDisplayName?: unknown
  isCrossingClosed?: unknown
  routeTravelTime?: unknown
  routeTravelTimeHist?: unknown
  timeStamp?: unknown
}

/** One crossing + direction ("lane"), upper level only, as we store and serve it. */
export interface BridgeCrossingLane {
  facilityId: number
  crossingName: string
  direction: BridgeCrossingDirection
  travelTimeMinutes: number
  typicalTimeMinutes: number | null
  isClosed: boolean
  sourceTimestamp: string | null
}

/**
 * Keep only the lanes the page shows: every crossing's two directions, using
 * the George Washington Bridge's upper level only — its only facility with a
 * level split (`facilityModifier`); every other crossing leaves it blank and
 * is unaffected by dropping "Lower".
 */
export function parseBridgeCrossingFeed(raw: unknown): BridgeCrossingLane[] {
  if (!Array.isArray(raw)) return []
  const lanes: BridgeCrossingLane[] = []

  for (const item of raw) {
    const entry = item as BridgeCrossingRawEntry
    if (!entry || typeof entry !== 'object') continue
    if (String(entry.facilityModifier ?? '') === 'Lower') continue

    const facilityId = Number(entry.facilityId)
    const travelTimeMinutes = Number(entry.routeTravelTime)
    const direction = entry.travelDirection
    if (!Number.isFinite(facilityId)) continue
    if (!Number.isFinite(travelTimeMinutes)) continue
    if (direction !== 'ToNY' && direction !== 'ToNJ') continue

    const typical = Number(entry.routeTravelTimeHist)
    lanes.push({
      facilityId,
      crossingName: String(entry.crossingDisplayName ?? '').trim() || `Crossing ${facilityId}`,
      direction,
      travelTimeMinutes,
      typicalTimeMinutes: Number.isFinite(typical) ? typical : null,
      isClosed: Boolean(entry.isCrossingClosed),
      sourceTimestamp: entry.timeStamp == null ? null : String(entry.timeStamp),
    })
  }
  return lanes
}

/** "Worsening"/"improving" vs. a reading from ~30 minutes ago — a single poll's jitter is not a trend. */
export function classifyBridgeCrossingTrend(
  currentMinutes: number,
  previousMinutes: number | null | undefined,
  thresholdMinutes = BRIDGE_CROSSING_TREND_THRESHOLD_MINUTES,
): BridgeCrossingTrend {
  if (previousMinutes == null || !Number.isFinite(previousMinutes)) return 'STEADY'
  const delta = currentMinutes - previousMinutes
  if (delta >= thresholdMinutes) return 'WORSENING'
  if (delta <= -thresholdMinutes) return 'IMPROVING'
  return 'STEADY'
}

/** A stable key for one bridge lane, for grouping snapshot rows into series. */
export function bridgeCrossingLaneKey(facilityId: number, direction: BridgeCrossingDirection): string {
  return `${facilityId}:${direction}`
}
