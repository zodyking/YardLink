<script setup lang="ts">
import { parsePin, SITE_RADIUS_MAX_M, SITE_RADIUS_MIN_M } from '#shared/utils/geo'
import { formatAddressSearchQuery } from '#shared/utils/us-address'
import { loadLeaflet, observeMapSize, waitForMapSize } from '~/utils/leaflet-map'
import {
  LABELS_ATTRIBUTION,
  LABELS_TILE_URL,
  OSM_ATTRIBUTION,
  osmTileUrl,
  ROADS_ATTRIBUTION,
  ROADS_TILE_URL,
  SATELLITE_ATTRIBUTION,
  satelliteTileUrl,
} from '~/utils/map-tiles'

/**
 * Where a site is, and how close counts as being there. The address puts the
 * pin down by itself; dragging it corrects what the map got wrong, and the
 * circle is what a phone crosses to say the driver has arrived.
 */
const US_CENTER: [number, number] = [39.8283, -98.5795]
const SITE_ZOOM = 17

const props = withDefaults(defineProps<{
  latitude: number | string | null
  longitude: number | string | null
  radiusMeters: number
  addressLine1?: string | null
  city?: string | null
  state?: string | null
  postalCode?: string | null
}>(), {
  addressLine1: null,
  city: null,
  state: null,
  postalCode: null,
})

const emit = defineEmits<{
  'update:pin': [{ latitude: number, longitude: number }]
  'update:radiusMeters': [value: number]
}>()

const mapEl = ref<HTMLElement | null>(null)
const ready = ref(false)
const errorMessage = ref('')
const basemap = ref<'satellite' | 'street'>('satellite')
const pin = ref<{ latitude: number, longitude: number } | null>(parsePin(props.latitude, props.longitude))

type LeafletModule = typeof import('leaflet')
let L: LeafletModule | null = null
let map: import('leaflet').Map | null = null
let baseLayer: import('leaflet').TileLayer | null = null
let labelsLayer: import('leaflet').LayerGroup | null = null
let marker: import('leaflet').Marker | null = null
let circle: import('leaflet').Circle | null = null
let cancelled = false
let stopSizeWatch: (() => void) | null = null
let recenterTimer: ReturnType<typeof setTimeout> | undefined

const radiusLabel = computed(() => {
  const feet = Math.round(props.radiusMeters * 3.28084)
  return `${props.radiusMeters} m · about ${feet.toLocaleString()} ft across the gate`
})

function paintBaseLayer() {
  if (!map || !L) return
  baseLayer?.remove()
  labelsLayer?.remove()
  labelsLayer = null
  if (basemap.value === 'satellite') {
    baseLayer = L.tileLayer(satelliteTileUrl(), {
      maxZoom: 22,
      maxNativeZoom: 19,
      attribution: SATELLITE_ATTRIBUTION,
    })
    baseLayer.addTo(map)
    baseLayer.bringToBack()
    labelsLayer = L.layerGroup()
    L.tileLayer(ROADS_TILE_URL, {
      maxZoom: 22,
      maxNativeZoom: 19,
      attribution: ROADS_ATTRIBUTION,
      pane: 'overlayPane',
    }).addTo(labelsLayer)
    L.tileLayer(LABELS_TILE_URL, {
      maxZoom: 22,
      maxNativeZoom: 19,
      attribution: LABELS_ATTRIBUTION,
      pane: 'overlayPane',
    }).addTo(labelsLayer)
    labelsLayer.addTo(map)
  }
  else {
    baseLayer = L.tileLayer(osmTileUrl(), {
      maxZoom: 22,
      maxNativeZoom: 19,
      attribution: OSM_ATTRIBUTION,
    })
    baseLayer.addTo(map)
    baseLayer.bringToBack()
  }
}

function paintSite() {
  if (!map || !L) return
  const at = pin.value
  marker?.remove()
  circle?.remove()
  marker = null
  circle = null
  if (!at) return

  circle = L.circle([at.latitude, at.longitude], {
    radius: props.radiusMeters,
    color: '#007DE0',
    weight: 2,
    fillColor: '#007DE0',
    fillOpacity: 0.12,
    interactive: false,
  }).addTo(map)

  marker = L.marker([at.latitude, at.longitude], {
    draggable: true,
    autoPan: true,
    icon: L.divIcon({
      className: 'site-pin',
      iconSize: [22, 22],
      iconAnchor: [11, 11],
    }),
    keyboard: true,
    title: 'Drag to move this site',
  }).addTo(map)

  marker.on('drag', () => {
    const at = marker?.getLatLng()
    if (at) circle?.setLatLng(at)
  })
  marker.on('dragend', () => {
    const next = marker?.getLatLng()
    if (!next) return
    pin.value = { latitude: next.lat, longitude: next.lng }
    emit('update:pin', pin.value)
  })
}

function applyView() {
  if (!map) return
  const at = pin.value
  try {
    map.setView(
      at ? [at.latitude, at.longitude] : US_CENTER,
      at ? SITE_ZOOM : 4,
      { animate: false },
    )
    if (at && circle) map.fitBounds(circle.getBounds(), { animate: false, padding: [28, 28], maxZoom: 19 })
  }
  catch {
    // Leaflet throws until the pane has a size; the resize watcher retries.
  }
}

/** Nominatim's structured search is the most accurate for a street address. */
async function geocodeStructured(): Promise<{ latitude: number, longitude: number } | null> {
  const street = props.addressLine1?.trim()
  if (!street || street.length < 3) return null
  const params = new URLSearchParams({
    street,
    format: 'jsonv2',
    countrycodes: 'us',
    limit: '1',
    addressdetails: '0',
  })
  if (props.city?.trim()) params.set('city', props.city.trim())
  if (props.state?.trim()) params.set('state', props.state.trim())
  if (props.postalCode?.trim()) params.set('postalcode', props.postalCode.trim())
  try {
    const results = await $fetch<Array<{ lat: string, lon: string }>>(
      `https://nominatim.openstreetmap.org/search?${params.toString()}`,
      { headers: { Accept: 'application/json' }, timeout: 6000 },
    )
    const hit = results?.[0]
    return hit ? parsePin(hit.lat, hit.lon) : null
  }
  catch {
    return null
  }
}

async function geocodeAddress(): Promise<{ latitude: number, longitude: number } | null> {
  const structured = await geocodeStructured()
  if (structured) return structured
  const q = formatAddressSearchQuery({
    addressLine1: props.addressLine1,
    city: props.city,
    state: props.state,
    postalCode: props.postalCode,
  })
  if (q.length < 3) return null
  try {
    const result = await $fetch('/api/geocode/search', { query: { q, limit: 1 } })
    const hit = result.results?.[0]
    return hit ? parsePin(hit.latitude, hit.longitude) : null
  }
  catch {
    return null
  }
}

async function resolveSite(): Promise<{ latitude: number, longitude: number } | null> {
  const given = parsePin(props.latitude, props.longitude)
  if (given) return given
  const found = await geocodeAddress()
  if (found) emit('update:pin', found)
  return found
}

async function recenterFromProps() {
  if (!ready.value) return
  const site = await resolveSite()
  if (cancelled || !site) return
  pin.value = site
  paintSite()
  applyView()
}

async function boot() {
  if (!import.meta.client || !mapEl.value) return
  try {
    const sized = await waitForMapSize(mapEl.value, () => cancelled)
    if (cancelled || !mapEl.value) return
    if (!sized) {
      errorMessage.value = 'Map did not get a size. Go back one step and open it again.'
      return
    }
    pin.value = await resolveSite()
    if (cancelled || !mapEl.value) return
    L = await loadLeaflet()
    if (cancelled || !mapEl.value) return
    map = L.map(mapEl.value, { zoomControl: true, attributionControl: true })
    paintBaseLayer()
    paintSite()
    map.invalidateSize()
    applyView()
    ready.value = true
    errorMessage.value = ''
    stopSizeWatch = observeMapSize(mapEl.value, () => {
      if (cancelled || !map) return
      map.invalidateSize()
    })
  }
  catch (error) {
    if (!cancelled) {
      errorMessage.value = 'Map failed to load. Save the address and open this page again.'
      console.warn('[LocationPinEditor]', error)
    }
  }
}

watch(() => props.radiusMeters, (value) => {
  if (!ready.value) return
  circle?.setRadius(value)
})

watch(() => [
  props.latitude,
  props.longitude,
  props.addressLine1,
  props.city,
  props.state,
  props.postalCode,
] as const, () => {
  clearTimeout(recenterTimer)
  recenterTimer = setTimeout(() => {
    void recenterFromProps()
  }, 350)
})

watch(basemap, () => {
  if (!ready.value) return
  paintBaseLayer()
})

onMounted(() => {
  cancelled = false
  boot()
})

onBeforeUnmount(() => {
  cancelled = true
  clearTimeout(recenterTimer)
  stopSizeWatch?.()
  stopSizeWatch = null
  try {
    map?.off()
    marker?.remove()
    circle?.remove()
    labelsLayer?.remove()
    baseLayer?.remove()
    map?.remove()
  }
  catch {
    // Leaflet throws if the pane was already detached during a route change.
  }
  map = null
  marker = null
  circle = null
  baseLayer = null
  labelsLayer = null
  L = null
})
</script>

<template>
  <div class="site-map-wrap">
    <div class="site-map-head">
      <div
        class="map-basemap"
        role="group"
        aria-label="Map style"
      >
        <button
          type="button"
          class="fchip"
          :class="{ on: basemap === 'satellite' }"
          :aria-pressed="basemap === 'satellite'"
          @click="basemap = 'satellite'"
        >
          Satellite
        </button>
        <button
          type="button"
          class="fchip"
          :class="{ on: basemap === 'street' }"
          :aria-pressed="basemap === 'street'"
          @click="basemap = 'street'"
        >
          Street
        </button>
      </div>
      <small>Drag the pin to the gate the driver uses.</small>
    </div>

    <div
      ref="mapEl"
      class="location-map place"
    />

    <label class="site-radius">
      <span>How close counts as arrived</span>
      <input
        :value="radiusMeters"
        class="site-radius-range"
        type="range"
        :min="SITE_RADIUS_MIN_M"
        :max="SITE_RADIUS_MAX_M"
        step="10"
        @input="emit('update:radiusMeters', Number(($event.target as HTMLInputElement).value))"
      >
      <small class="field-hint">{{ radiusLabel }}</small>
    </label>

    <p
      v-if="errorMessage"
      class="banner err"
      role="alert"
    >
      <span aria-hidden="true">✕</span>
      <span>{{ errorMessage }}</span>
    </p>
  </div>
</template>
