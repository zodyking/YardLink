<script setup lang="ts">
import { SHIPCSX_LOOKUP_URL, SHIPCSX_REFERENCE, shipcsxEquipmentParts } from '#shared/utils/csx-lookup'
import { copyTextToClipboard } from '~/utils/share-trip-sms'

/**
 * Check containers on ShipCSX by hand. ShipCSX opens in a new tab, where the
 * person passes its human check, picks the CSX location and searches; this
 * panel hands them each container's initial and number to paste in.
 */
const props = defineProps<{
  containers: string[]
  /** The CSX location to pick, when the site says. */
  terminal?: string | null
}>()

const rows = computed(() => props.containers.flatMap((number) => {
  const parts = shipcsxEquipmentParts(number)
  return parts ? [{ key: number, ...parts }] : []
}))
const copied = ref('')

async function copy(text: string) {
  copied.value = (await copyTextToClipboard(text)) ? text : ''
}
</script>

<template>
  <div class="csx-block">
    <div class="csx-block-head">
      <span class="eyebrow">ShipCSX</span>
      <strong>{{ terminal ? `Pick ${terminal} on ShipCSX` : 'Check on ShipCSX' }}</strong>
    </div>
    <p class="csx-block-note">
      Open ShipCSX, tick "Verify you are human" if it asks, then copy each box below into the form.
      Reference: {{ SHIPCSX_REFERENCE }}.
    </p>
    <ul
      v-if="rows.length"
      class="csx-copy-list"
    >
      <li
        v-for="row in rows"
        :key="row.key"
      >
        <button
          type="button"
          class="csx-copy mono"
          :aria-label="`Copy initial ${row.initial}`"
          @click="copy(row.initial)"
        >
          {{ row.initial }}
        </button>
        <button
          type="button"
          class="csx-copy mono"
          :aria-label="`Copy number ${row.number}`"
          @click="copy(row.number)"
        >
          {{ row.number }}
        </button>
        <span
          v-if="copied === row.initial || copied === row.number"
          class="csx-block-meta"
          role="status"
        >Copied</span>
      </li>
    </ul>
    <a
      :href="SHIPCSX_LOOKUP_URL"
      target="_blank"
      rel="noopener"
      class="btn-ghost w-full"
    >Open ShipCSX</a>
  </div>
</template>
