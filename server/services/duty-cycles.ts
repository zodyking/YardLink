import { and, asc, desc, eq, inArray, isNull, sql } from 'drizzle-orm'
import type { DbExecutor } from '../utils/db'
import {
  chassis as chassisTable,
  containerDutyCycles,
  containerEvents,
  containers,
  locations,
  trips,
  users,
} from '../database/schema'
import type { EventType, LocationType } from '#shared/utils/domain'
import { chassisPairings, cycleStep, replayDutyCycles } from '#shared/utils/duty-cycle'

export type DutyCycle = typeof containerDutyCycles.$inferSelect

export interface CycleEventInput {
  eventId: string
  companyId: string
  containerId: string
  eventType: EventType
  occurredAt: Date
  tripId?: string | null
  locationId?: string | null
  actorDriverId?: string | null
}

async function locationTypeOf(tx: DbExecutor, companyId: string, locationId?: string | null): Promise<LocationType | null> {
  if (!locationId) return null
  const [row] = await tx
    .select({ type: locations.type })
    .from(locations)
    .where(and(eq(locations.id, locationId), eq(locations.companyId, companyId)))
    .limit(1)
  return (row?.type as LocationType | undefined) ?? null
}

async function activeCycleFor(tx: DbExecutor, containerId: string): Promise<DutyCycle | null> {
  const [row] = await tx
    .select()
    .from(containerDutyCycles)
    .where(and(eq(containerDutyCycles.containerId, containerId), eq(containerDutyCycles.status, 'ACTIVE')))
    .limit(1)
  return row ?? null
}

async function latestCycleFor(tx: DbExecutor, containerId: string): Promise<DutyCycle | null> {
  const [row] = await tx
    .select()
    .from(containerDutyCycles)
    .where(eq(containerDutyCycles.containerId, containerId))
    .orderBy(desc(containerDutyCycles.sequence))
    .limit(1)
  return row ?? null
}

/**
 * File a just-recorded container event under its duty cycle, opening or
 * completing the cycle when the event calls for it. Runs inside the same
 * transaction as the event, so history and cycle state cannot drift apart.
 *
 * The rules live in `shared/utils/duty-cycle.ts`; this only applies them.
 */
export async function fileEventUnderCycle(tx: DbExecutor, input: CycleEventInput): Promise<string | null> {
  const [locationType, existing] = await Promise.all([
    locationTypeOf(tx, input.companyId, input.locationId),
    activeCycleFor(tx, input.containerId),
  ])
  let active = existing

  const step = cycleStep({
    eventType: input.eventType,
    locationType,
    hasActiveCycle: Boolean(active),
    tripId: input.tripId,
    activeCycleStartTripId: active?.startTripId,
  })

  if (step.closeStale && active) {
    await tx
      .update(containerDutyCycles)
      .set({
        status: 'COMPLETED',
        completedAt: input.occurredAt,
        endLocationId: input.locationId ?? null,
        closedByNextPickup: true,
        updatedAt: new Date(),
      })
      .where(eq(containerDutyCycles.id, active.id))
    active = null
  }

  if (step.open) {
    const [last] = await tx
      .select({ value: sql<number>`coalesce(max(${containerDutyCycles.sequence}), 0)::int` })
      .from(containerDutyCycles)
      .where(eq(containerDutyCycles.containerId, input.containerId))
    const [created] = await tx
      .insert(containerDutyCycles)
      .values({
        companyId: input.companyId,
        containerId: input.containerId,
        sequence: (last?.value ?? 0) + 1,
        status: 'ACTIVE',
        startedAt: input.occurredAt,
        startEventId: input.eventId,
        startLocationId: input.locationId ?? null,
        startTripId: input.tripId ?? null,
        startDriverId: input.actorDriverId ?? null,
      })
      .returning()
    active = created ?? null

    // Events the same trip wrote before its cycle existed (pickup started).
    if (active && input.tripId) {
      await tx
        .update(containerEvents)
        .set({ dutyCycleId: active.id })
        .where(and(
          eq(containerEvents.tripId, input.tripId),
          eq(containerEvents.containerId, input.containerId),
          isNull(containerEvents.dutyCycleId),
        ))
    }
  }

  let cycle: DutyCycle | null = null
  if (step.attach === 'ACTIVE') cycle = active
  else if (step.attach === 'LATEST') cycle = await latestCycleFor(tx, input.containerId)

  if (cycle) {
    await tx
      .update(containerEvents)
      .set({ dutyCycleId: cycle.id })
      .where(eq(containerEvents.id, input.eventId))
    if (input.tripId) {
      await tx
        .update(trips)
        .set({ dutyCycleId: cycle.id })
        .where(and(eq(trips.id, input.tripId), eq(trips.containerId, input.containerId)))
    }
  }

  if (active && (step.void || step.complete)) {
    await tx
      .update(containerDutyCycles)
      .set({
        status: step.void ? 'VOIDED' : 'COMPLETED',
        completedAt: input.occurredAt,
        endEventId: input.eventId,
        endLocationId: step.void ? null : (input.locationId ?? null),
        endTripId: step.void ? null : (input.tripId ?? null),
        endDriverId: input.actorDriverId ?? null,
        updatedAt: new Date(),
      })
      .where(eq(containerDutyCycles.id, active.id))
  }

  return cycle?.id ?? null
}

/**
 * Build cycles for containers whose history predates duty cycles. Only
 * containers with events and no cycle rows are touched, so this is safe to
 * run on every boot.
 */
export async function backfillDutyCycles(db: DbExecutor): Promise<number> {
  const pending = await db
    .selectDistinct({ containerId: containerEvents.containerId, companyId: containerEvents.companyId })
    .from(containerEvents)
    .where(sql`${containerEvents.containerId} is not null and not exists (
      select 1 from ${containerDutyCycles} c where c.container_id = ${containerEvents.containerId}
    )`)

  let built = 0
  for (const row of pending) {
    if (!row.containerId) continue
    const containerId = row.containerId
    const events = await db
      .select({
        id: containerEvents.id,
        eventType: containerEvents.eventType,
        occurredAt: containerEvents.occurredAt,
        tripId: containerEvents.tripId,
        locationId: containerEvents.locationId,
        actorDriverId: containerEvents.actorDriverId,
        locationType: locations.type,
      })
      .from(containerEvents)
      .leftJoin(locations, eq(locations.id, containerEvents.locationId))
      .where(eq(containerEvents.containerId, containerId))
      .orderBy(asc(containerEvents.occurredAt), asc(containerEvents.createdAt))

    const driverByEvent = new Map(events.map(event => [event.id, event.actorDriverId]))
    const cycles = replayDutyCycles(events.map(event => ({
      id: event.id,
      eventType: event.eventType as EventType,
      occurredAt: event.occurredAt,
      tripId: event.tripId,
      locationId: event.locationId,
      locationType: (event.locationType as LocationType | null) ?? null,
    })))

    for (const cycle of cycles) {
      const [created] = await db
        .insert(containerDutyCycles)
        .values({
          companyId: row.companyId,
          containerId,
          sequence: cycle.sequence,
          status: cycle.status,
          startedAt: new Date(cycle.startedAt),
          startEventId: cycle.startEventId,
          startLocationId: cycle.startLocationId,
          startTripId: cycle.startTripId,
          startDriverId: driverByEvent.get(cycle.startEventId) ?? null,
          completedAt: cycle.completedAt ? new Date(cycle.completedAt) : null,
          endEventId: cycle.endEventId,
          endLocationId: cycle.endLocationId,
          endTripId: cycle.endTripId,
          endDriverId: cycle.endEventId ? (driverByEvent.get(cycle.endEventId) ?? null) : null,
          closedByNextPickup: cycle.closedByNextPickup,
        })
        .onConflictDoNothing()
        .returning({ id: containerDutyCycles.id })
      if (!created || !cycle.eventIds.length) continue

      await db
        .update(containerEvents)
        .set({ dutyCycleId: created.id })
        .where(inArray(containerEvents.id, cycle.eventIds))

      const tripIds = [...new Set(events
        .filter(event => cycle.eventIds.includes(event.id) && event.tripId)
        .map(event => event.tripId as string))]
      if (tripIds.length) {
        await db
          .update(trips)
          .set({ dutyCycleId: created.id })
          .where(and(inArray(trips.id, tripIds), eq(trips.containerId, containerId)))
      }
    }
    built += cycles.length
  }
  return built
}

/* ------------------------------------------------------------------ */
/* Read models for the equipment history screens                       */
/* ------------------------------------------------------------------ */

function fullName(first?: string | null, last?: string | null): string | null {
  const name = `${first ?? ''} ${last ?? ''}`.trim()
  return name || null
}

async function timelineRows(db: DbExecutor, companyId: string, where: ReturnType<typeof and>) {
  const rows = await db
    .select({
      id: containerEvents.id,
      eventType: containerEvents.eventType,
      occurredAt: containerEvents.occurredAt,
      tripId: containerEvents.tripId,
      dutyCycleId: containerEvents.dutyCycleId,
      containerId: containerEvents.containerId,
      containerNumber: containers.number,
      chassisId: containerEvents.chassisId,
      chassisNumber: chassisTable.number,
      locationId: containerEvents.locationId,
      locationName: locations.name,
      locationType: locations.type,
      actorDriverId: containerEvents.actorDriverId,
      driverFirstName: users.firstName,
      driverLastName: users.lastName,
      tripReference: trips.reference,
      notes: containerEvents.notes,
      payload: containerEvents.payload,
    })
    .from(containerEvents)
    .leftJoin(containers, eq(containers.id, containerEvents.containerId))
    .leftJoin(chassisTable, eq(chassisTable.id, containerEvents.chassisId))
    .leftJoin(locations, eq(locations.id, containerEvents.locationId))
    // Whoever did it — a driver on a trip, or a dispatcher correcting a yard.
    .leftJoin(users, eq(users.id, containerEvents.actorUserId))
    .leftJoin(trips, eq(trips.id, containerEvents.tripId))
    .where(and(eq(containerEvents.companyId, companyId), where))
    .orderBy(asc(containerEvents.occurredAt), asc(containerEvents.createdAt))
    .limit(2000)

  return rows.map(row => ({
    id: row.id,
    eventType: row.eventType as EventType,
    occurredAt: row.occurredAt,
    tripId: row.tripId,
    tripReference: row.tripReference,
    dutyCycleId: row.dutyCycleId,
    containerId: row.containerId,
    containerNumber: row.containerNumber,
    chassisId: row.chassisId,
    chassisNumber: row.chassisNumber,
    locationId: row.locationId,
    locationName: row.locationName,
    locationType: row.locationType as LocationType | null,
    actorDriverId: row.actorDriverId,
    driverName: fullName(row.driverFirstName, row.driverLastName),
    notes: row.notes,
    isLoaded: typeof row.payload?.isLoaded === 'boolean' ? row.payload.isLoaded : null,
    sealNumber: typeof row.payload?.sealNumber === 'string' ? row.payload.sealNumber : null,
  }))
}

export type HistoryEvent = Awaited<ReturnType<typeof timelineRows>>[number]

/** Every duty cycle of one container, newest first, each with its own events. */
export async function loadContainerHistory(db: DbExecutor, companyId: string, containerId: string) {
  const [cycles, events] = await Promise.all([
    db
      .select()
      .from(containerDutyCycles)
      .where(and(eq(containerDutyCycles.companyId, companyId), eq(containerDutyCycles.containerId, containerId)))
      .orderBy(desc(containerDutyCycles.sequence)),
    timelineRows(db, companyId, eq(containerEvents.containerId, containerId)),
  ])

  const locationIds = [...new Set(cycles.flatMap(cycle => [cycle.startLocationId, cycle.endLocationId]).filter(Boolean) as string[])]
  const names = locationIds.length
    ? await db.select({ id: locations.id, name: locations.name, type: locations.type }).from(locations).where(inArray(locations.id, locationIds))
    : []
  const place = new Map(names.map(row => [row.id, row]))

  const byCycle = new Map<string, HistoryEvent[]>()
  const unfiled: HistoryEvent[] = []
  for (const event of events) {
    if (!event.dutyCycleId) {
      unfiled.push(event)
      continue
    }
    const list = byCycle.get(event.dutyCycleId) ?? []
    list.push(event)
    byCycle.set(event.dutyCycleId, list)
  }

  return {
    cycles: cycles.map((cycle) => {
      const cycleEvents = (byCycle.get(cycle.id) ?? []).slice().reverse()
      const driversSeen = [...new Set(cycleEvents.map(event => event.driverName).filter(Boolean) as string[])]
      const chassisSeen = [...new Map(cycleEvents
        .filter(event => event.chassisId && event.chassisNumber)
        .map(event => [event.chassisId as string, { id: event.chassisId as string, number: event.chassisNumber as string }])).values()]
      return {
        id: cycle.id,
        sequence: cycle.sequence,
        status: cycle.status,
        startedAt: cycle.startedAt,
        startLocation: cycle.startLocationId ? (place.get(cycle.startLocationId) ?? null) : null,
        completedAt: cycle.completedAt,
        endLocation: cycle.endLocationId ? (place.get(cycle.endLocationId) ?? null) : null,
        closedByNextPickup: cycle.closedByNextPickup,
        drivers: driversSeen,
        chassis: chassisSeen,
        events: cycleEvents,
      }
    }),
    /** Staging at a terminal before the first pickup, newest first. */
    unfiled: unfiled.reverse(),
  }
}

/** One chassis: its full event trail and the containers it has carried. */
export async function loadChassisHistory(db: DbExecutor, companyId: string, chassisId: string) {
  const events = await timelineRows(db, companyId, eq(containerEvents.chassisId, chassisId))

  const pairings = chassisPairings(events.map(event => ({
    id: event.id,
    eventType: event.eventType,
    occurredAt: event.occurredAt,
    containerId: event.containerId,
    dutyCycleId: event.dutyCycleId,
    tripId: event.tripId,
    locationId: event.locationId,
    actorDriverId: event.actorDriverId,
  })))

  const byId = new Map(events.map(event => [event.id, event]))
  const cycleIds = [...new Set(pairings.map(pairing => pairing.dutyCycleId).filter(Boolean) as string[])]
  const cycles = cycleIds.length
    ? await db
        .select({ id: containerDutyCycles.id, sequence: containerDutyCycles.sequence, status: containerDutyCycles.status })
        .from(containerDutyCycles)
        .where(inArray(containerDutyCycles.id, cycleIds))
    : []
  const cycleById = new Map(cycles.map(cycle => [cycle.id, cycle]))

  return {
    events: events.slice().reverse(),
    pairings: pairings.reverse().map((pairing) => {
      const paired = byId.get(pairing.pairedEventId)
      const separated = pairing.separatedEventId ? byId.get(pairing.separatedEventId) : null
      const cycle = pairing.dutyCycleId ? cycleById.get(pairing.dutyCycleId) : null
      return {
        containerId: pairing.containerId,
        containerNumber: paired?.containerNumber ?? null,
        dutyCycleId: pairing.dutyCycleId,
        dutyCycleSequence: cycle?.sequence ?? null,
        dutyCycleStatus: cycle?.status ?? null,
        pairedAt: pairing.pairedAt,
        pairedLocationName: paired?.locationName ?? null,
        pairedByDriverName: paired?.driverName ?? null,
        separatedAt: pairing.separatedAt,
        separatedLocationName: separated?.locationName ?? null,
        separatedByDriverName: separated?.driverName ?? null,
      }
    }),
  }
}
