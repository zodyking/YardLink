import { and, eq, ilike, isNull, or } from 'drizzle-orm'
import { chassis as chassisTable, containerDutyCycles, containers, locations } from '../database/schema'
import type { Database, DbExecutor } from '../utils/db'
import { recordEvent } from './events'
import { shipcsxShowsInGated, waybillDuringCycle, type CsxLookupCard } from '#shared/utils/csx-lookup'
import { containerStatusAfterDropoff, dropoffCompletesServiceLife } from '#shared/utils/service-life'

const NOTE = 'Recorded by Yard Link: ShipCSX shows this container in-gated, but its return was never logged.'

/** The company's location for a ShipCSX terminal. */
async function csxLocationFor(db: DbExecutor, companyId: string, terminal: string) {
  const [row] = await db
    .select({ id: locations.id, type: locations.type })
    .from(locations)
    .where(and(
      eq(locations.companyId, companyId),
      eq(locations.status, 'ACTIVE'),
      isNull(locations.deletedAt),
      or(
        ilike(locations.shipcsxTerminal, terminal),
        and(eq(locations.type, 'RAIL_TERMINAL'), ilike(locations.name, `%${terminal}%`)),
      ),
    ))
    .limit(1)
  return row ?? null
}

/**
 * When ShipCSX shows a box in-gated at its terminal but Yard Link still has it
 * sitting at a customer or yard, the return happened without anyone logging
 * it. Record it the way a trip would have — picked up where it sat, dropped
 * off at the terminal — by an unknown driver, so the container's place and
 * history match CSX. Only an in-gate on a waybill cut during the current
 * cycle counts, so an old visit on ShipCSX never moves a box.
 *
 * Returns true when the container was moved.
 */
export async function recordUnloggedCsxReturn(
  db: Database,
  input: { companyId: string, containerId: string, terminal: string, card: CsxLookupCard, seenAt: Date },
): Promise<boolean> {
  if (!shipcsxShowsInGated(input.card)) return false

  return db.transaction(async (tx) => {
    const [box] = await tx
      .select()
      .from(containers)
      .where(and(eq(containers.id, input.containerId), eq(containers.companyId, input.companyId)))
      .limit(1)
      .for('update')
    // Only a box parked somewhere; one a driver holds is on a live trip.
    if (!box || box.deletedAt || box.activePoolState !== 'AT_LOCATION' || !box.currentLocationId) return false

    const [cycle] = await tx
      .select({ startedAt: containerDutyCycles.startedAt })
      .from(containerDutyCycles)
      .where(and(eq(containerDutyCycles.containerId, box.id), eq(containerDutyCycles.status, 'ACTIVE')))
      .limit(1)
    if (!cycle || !waybillDuringCycle(input.card.waybillDate, cycle.startedAt)) return false

    const terminal = await csxLocationFor(tx, input.companyId, input.terminal)
    if (!terminal || terminal.id === box.currentLocationId) return false

    const isFinalRelease = dropoffCompletesServiceLife(terminal.type)
    const containerStatus = containerStatusAfterDropoff(terminal.type)
    const payload = {
      unknownDriver: true,
      shipcsx: { terminal: input.terminal, inGateReadiness: input.card.inGateReadiness, waybillDate: input.card.waybillDate },
    }

    await recordEvent(
      tx,
      {
        id: crypto.randomUUID(),
        companyId: input.companyId,
        containerId: box.id,
        eventType: 'PICKUP_CONFIRMED',
        occurredAt: input.seenAt,
        source: 'SYSTEM',
        locationId: box.currentLocationId,
        chassisId: box.currentChassisId,
        payload: { ...payload, isLoaded: box.isLoaded, sealNumber: box.sealNumber },
        notes: NOTE,
      },
      {
        activePoolState: 'DRIVER_CUSTODY',
        currentDriverId: null,
        currentLocationId: null,
        containerStatus: 'IN_TRANSIT',
      },
    )

    await recordEvent(
      tx,
      {
        id: crypto.randomUUID(),
        companyId: input.companyId,
        containerId: box.id,
        eventType: 'DROPOFF_CONFIRMED',
        occurredAt: new Date(input.seenAt.getTime() + 1),
        source: 'SYSTEM',
        locationId: terminal.id,
        chassisId: box.currentChassisId,
        payload: { ...payload, isFinalRelease, locationType: terminal.type, containerStatus },
        notes: NOTE,
      },
      {
        activePoolState: isFinalRelease ? 'INACTIVE' : 'AT_LOCATION',
        currentDriverId: null,
        currentLocationId: terminal.id,
        activeMovementId: null,
        releasedAt: isFinalRelease ? input.seenAt : null,
        containerStatus,
      },
    )

    // The chassis went in with the box.
    if (box.currentChassisId) {
      await tx
        .update(chassisTable)
        .set({ currentLocationId: terminal.id, updatedAt: new Date() })
        .where(and(eq(chassisTable.id, box.currentChassisId), eq(chassisTable.companyId, input.companyId)))
    }

    if (isFinalRelease) {
      await recordEvent(tx, {
        id: crypto.randomUUID(),
        companyId: input.companyId,
        containerId: box.id,
        eventType: 'RELEASED',
        occurredAt: new Date(input.seenAt.getTime() + 2),
        source: 'SYSTEM',
        locationId: terminal.id,
        payload,
        notes: 'Final release from the tracked network.',
      })
    }
    return true
  })
}
