<script setup lang="ts">
/**
 * Equipment history as a plain timeline.
 *
 * Container: one duty cycle at a time — when and where it started, who moved
 * it, which chassis carried it, and whether it has gone back to a terminal —
 * with earlier cycles one tap away. The same number returning months later is
 * a new cycle, never mixed into the old one.
 *
 * Chassis: one continuous trail, plus every container it has carried and the
 * duty cycle each of those belonged to.
 */
import { DUTY_CYCLE_STATUS_LABELS, dutyCycleLabel } from '#shared/utils/duty-cycle'
import type { DutyCycleStatus } from '#shared/utils/duty-cycle'
import type { EventType, LocationType } from '#shared/utils/domain'
import { formatChassisNumber, formatContainerNumber } from '#shared/utils/iso6346'

interface HistoryEvent {
  id: string
  eventType: EventType
  occurredAt: string
  tripId: string | null
  tripReference: string | null
  dutyCycleId: string | null
  containerId: string | null
  containerNumber: string | null
  chassisId: string | null
  chassisNumber: string | null
  locationName: string | null
  locationType: LocationType | null
  driverName: string | null
  notes: string | null
  isLoaded: boolean | null
  sealNumber: string | null
}
interface Place { id: string, name: string, type: string }
interface Cycle {
  id: string
  sequence: number
  status: DutyCycleStatus
  startedAt: string
  startLocation: Place | null
  completedAt: string | null
  endLocation: Place | null
  closedByNextPickup: boolean
  drivers: string[]
  chassis: Array<{ id: string, number: string }>
  events: HistoryEvent[]
}
interface Pairing {
  containerId: string
  containerNumber: string | null
  dutyCycleId: string | null
  dutyCycleSequence: number | null
  dutyCycleStatus: DutyCycleStatus | null
  pairedAt: string
  pairedLocationName: string | null
  pairedByDriverName: string | null
  separatedAt: string | null
  separatedLocationName: string | null
  separatedByDriverName: string | null
}

const props = defineProps<{
  subject: 'container' | 'chassis'
  cycles?: Cycle[]
  unfiled?: HistoryEvent[]
  events?: HistoryEvent[]
  pairings?: Pairing[]
  /** Open on this cycle (from a chassis pairing link). */
  initialCycleId?: string | null
}>()

const cycles = computed(() => props.cycles ?? [])
const selectedId = ref<string | null>(null)
watch(
  () => [cycles.value.map(cycle => cycle.id).join('|'), props.initialCycleId] as const,
  () => {
    const wanted = props.initialCycleId && cycles.value.some(cycle => cycle.id === props.initialCycleId)
      ? props.initialCycleId
      : null
    if (wanted) selectedId.value = wanted
    else if (!selectedId.value || !cycles.value.some(cycle => cycle.id === selectedId.value)) {
      selectedId.value = cycles.value[0]?.id ?? null
    }
  },
  { immediate: true },
)
const selected = computed(() => cycles.value.find(cycle => cycle.id === selectedId.value) ?? null)

const TITLES: Partial<Record<EventType, string>> = {
  PICKUP_STARTED: 'Pickup started',
  PICKUP_CONFIRMED: 'Picked up',
  DROPOFF_CONFIRMED: 'Dropped off',
  CHASSIS_ATTACH: 'Paired with chassis',
  CHASSIS_DETACH: 'Separated from chassis',
  YARD_MOVE: 'Moved',
  ACTIVATED: 'Added to the yard',
  RELEASED: 'Returned and released',
  PICKUP_CANCELLED: 'Pickup cancelled',
  CORRECTION: 'Correction',
  DAMAGE_REPORTED: 'Damage reported',
  DOCUMENT_ADDED: 'Document added',
  LOADED: 'Loaded',
  EMPTIED: 'Emptied',
}
/** What a driver or dispatcher needs to follow the equipment; the rest is noise. */
const SHOWN = new Set<EventType>([
  'PICKUP_CONFIRMED',
  'DROPOFF_CONFIRMED',
  'CHASSIS_ATTACH',
  'CHASSIS_DETACH',
  'YARD_MOVE',
  'ACTIVATED',
  'RELEASED',
  'PICKUP_CANCELLED',
  'CORRECTION',
  'DAMAGE_REPORTED',
  'LOADED',
  'EMPTIED',
])

function shown(events: HistoryEvent[] | undefined) {
  return (events ?? []).filter(event => SHOWN.has(event.eventType))
}

function title(event: HistoryEvent) {
  if (props.subject === 'chassis') {
    if (event.eventType === 'CHASSIS_ATTACH') return 'Paired with container'
    if (event.eventType === 'CHASSIS_DETACH') return 'Separated from container'
    if (!event.containerId && event.eventType === 'PICKUP_CONFIRMED') return 'Picked up bare'
    if (!event.containerId && event.eventType === 'DROPOFF_CONFIRMED') return 'Dropped off bare'
  }
  // Hooking up to a box already on a chassis moves both, and is not a pairing.
  if (event.eventType === 'PICKUP_CONFIRMED' && event.containerId && event.chassisId) {
    return 'Container and chassis picked up'
  }
  return TITLES[event.eventType] ?? event.eventType.toLowerCase().replace(/_/g, ' ')
}

function tone(event: HistoryEvent) {
  if (event.eventType === 'PICKUP_CONFIRMED') return 'up'
  if (event.eventType === 'DROPOFF_CONFIRMED' || event.eventType === 'RELEASED') return 'down'
  if (event.eventType === 'CHASSIS_ATTACH' || event.eventType === 'CHASSIS_DETACH') return 'link'
  return 'note'
}

function other(event: HistoryEvent) {
  if (props.subject === 'container') {
    return event.chassisNumber ? `Chassis ${formatChassisNumber(event.chassisNumber) || event.chassisNumber}` : ''
  }
  return event.containerNumber ? `Container ${formatContainerNumber(event.containerNumber) || event.containerNumber}` : ''
}

function when(value: string | null) {
  if (!value) return ''
  return new Date(value).toLocaleString(undefined, { month: 'short', day: 'numeric', year: 'numeric', hour: 'numeric', minute: '2-digit' })
}
function day(value: string | null) {
  if (!value) return ''
  return new Date(value).toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' })
}

function cycleVariant(status: DutyCycleStatus) {
  if (status === 'ACTIVE') return 'transit'
  if (status === 'COMPLETED') return 'ok'
  return 'idle'
}

function box(pairing: Pairing) {
  return pairing.containerNumber ? (formatContainerNumber(pairing.containerNumber) || pairing.containerNumber) : 'Container'
}
</script>

<template>
  <div class="eh">
    <!-- ───────────── Container ───────────── -->
    <template v-if="subject === 'container'">
      <div
        v-if="cycles.length > 1"
        class="eh-cycles"
        role="tablist"
        aria-label="Duty cycles"
      >
        <button
          v-for="cycle in cycles"
          :key="cycle.id"
          class="eh-cycle-tab"
          :class="{ on: cycle.id === selectedId }"
          role="tab"
          type="button"
          :aria-selected="cycle.id === selectedId"
          @click="selectedId = cycle.id"
        >
          <b>{{ dutyCycleLabel(cycle.sequence) }}</b>
          <small>{{ cycle.status === 'ACTIVE' ? 'Current' : day(cycle.startedAt) }}</small>
        </button>
      </div>

      <template v-if="selected">
        <div class="eh-summary">
          <div class="eh-summary-top">
            <b>{{ dutyCycleLabel(selected.sequence) }}</b>
            <StatusChip
              :variant="cycleVariant(selected.status)"
              :label="DUTY_CYCLE_STATUS_LABELS[selected.status]"
            />
          </div>
          <dl>
            <div>
              <dt>Started</dt>
              <dd>{{ when(selected.startedAt) }}<span v-if="selected.startLocation"> · {{ selected.startLocation.name }}</span></dd>
            </div>
            <div>
              <dt>{{ selected.status === 'VOIDED' ? 'Cancelled' : 'Returned' }}</dt>
              <dd v-if="selected.completedAt">
                {{ when(selected.completedAt) }}<span v-if="selected.endLocation"> · {{ selected.endLocation.name }}</span>
                <small v-if="selected.closedByNextPickup"> Closed when it was next collected from a terminal — the return was not recorded.</small>
              </dd>
              <dd v-else>
                Not yet — still out
              </dd>
            </div>
            <div v-if="selected.drivers.length">
              <dt>{{ selected.drivers.length === 1 ? 'Driver' : 'Drivers' }}</dt>
              <dd>{{ selected.drivers.join(', ') }}</dd>
            </div>
            <div v-if="selected.chassis.length">
              <dt>Chassis</dt>
              <dd>
                <NuxtLink
                  v-for="item in selected.chassis"
                  :key="item.id"
                  :to="`/chassis/${item.id}`"
                  class="eh-link"
                >{{ formatChassisNumber(item.number) || item.number }}</NuxtLink>
              </dd>
            </div>
          </dl>
        </div>

        <ol class="eh-line">
          <li
            v-for="event in shown(selected.events)"
            :key="event.id"
            :class="tone(event)"
          >
            <div class="eh-node">
              <b>{{ title(event) }}</b>
              <time>{{ when(event.occurredAt) }}</time>
            </div>
            <p>
              <span v-if="event.locationName">{{ event.locationName }}</span>
              <span v-if="other(event)">{{ other(event) }}</span>
              <span v-if="event.driverName">{{ event.driverName }}</span>
              <span v-if="event.isLoaded !== null && (event.eventType === 'PICKUP_CONFIRMED' || event.eventType === 'DROPOFF_CONFIRMED')">{{ event.isLoaded ? 'Loaded' : 'Empty' }}</span>
              <span v-if="event.sealNumber">Seal {{ event.sealNumber }}</span>
            </p>
            <p
              v-if="event.notes"
              class="eh-note"
            >
              {{ event.notes }}
            </p>
          </li>
        </ol>
      </template>

      <EmptyState
        v-else
        glyph="⇄"
        title="No movements yet"
        description="The first pickup starts this container's first duty cycle. Every pickup, drop-off and chassis change is listed here."
      />

      <details
        v-if="shown(unfiled).length"
        class="eh-unfiled"
      >
        <summary>Before the first duty cycle ({{ shown(unfiled).length }})</summary>
        <ol class="eh-line">
          <li
            v-for="event in shown(unfiled)"
            :key="event.id"
            class="note"
          >
            <div class="eh-node">
              <b>{{ title(event) }}</b>
              <time>{{ when(event.occurredAt) }}</time>
            </div>
            <p>
              <span v-if="event.locationName">{{ event.locationName }}</span>
              <span v-if="event.driverName">{{ event.driverName }}</span>
            </p>
          </li>
        </ol>
      </details>
    </template>

    <!-- ───────────── Chassis ───────────── -->
    <template v-else>
      <div
        v-if="pairings?.length"
        class="eh-pairings"
      >
        <div class="eh-sub">
          Containers carried
        </div>
        <NuxtLink
          v-for="pairing in pairings"
          :key="`${pairing.containerId}-${pairing.pairedAt}`"
          :to="{ path: `/containers/${pairing.containerId}`, query: pairing.dutyCycleId ? { cycle: pairing.dutyCycleId } : undefined }"
          class="eh-pairing"
        >
          <div>
            <b>{{ box(pairing) }}</b>
            <small v-if="pairing.dutyCycleSequence">{{ dutyCycleLabel(pairing.dutyCycleSequence) }}</small>
            <StatusChip
              v-if="!pairing.separatedAt"
              variant="transit"
              label="On it now"
            />
          </div>
          <p>
            Paired {{ when(pairing.pairedAt) }}<span v-if="pairing.pairedLocationName"> · {{ pairing.pairedLocationName }}</span><span v-if="pairing.pairedByDriverName"> · {{ pairing.pairedByDriverName }}</span>
          </p>
          <p v-if="pairing.separatedAt">
            Separated {{ when(pairing.separatedAt) }}<span v-if="pairing.separatedLocationName"> · {{ pairing.separatedLocationName }}</span><span v-if="pairing.separatedByDriverName"> · {{ pairing.separatedByDriverName }}</span>
          </p>
        </NuxtLink>
      </div>

      <div
        v-if="shown(events).length"
        class="eh-sub"
      >
        Full history
      </div>
      <ol
        v-if="shown(events).length"
        class="eh-line"
      >
        <li
          v-for="event in shown(events)"
          :key="event.id"
          :class="tone(event)"
        >
          <div class="eh-node">
            <b>{{ title(event) }}</b>
            <time>{{ when(event.occurredAt) }}</time>
          </div>
          <p>
            <span v-if="event.locationName">{{ event.locationName }}</span>
            <span v-if="other(event)">{{ other(event) }}</span>
            <span v-if="event.driverName">{{ event.driverName }}</span>
          </p>
        </li>
      </ol>
      <EmptyState
        v-else
        glyph="⇄"
        title="No movements yet"
        description="Pickups, drop-offs and every container this chassis carries are listed here."
      />
    </template>
  </div>
</template>
