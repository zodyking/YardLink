<script setup lang="ts">
/**
 * Import locations from a spreadsheet (CSV). The file is read on this device
 * first, so the dispatcher sees how many locations will be added and which
 * rows have a problem before anything is saved.
 */
import { locationImportTemplate, parseLocationImport } from '#shared/utils/location-import'
import type { LocationImportIssue, LocationImportParse } from '#shared/utils/location-import'
import { downloadTextFile } from '~/utils/download-text'

const props = defineProps<{ open: boolean }>()
const emit = defineEmits<{ close: [], imported: [] }>()

const fileName = ref('')
const csv = ref('')
const preview = ref<LocationImportParse | null>(null)
const importing = ref(false)
const failure = ref('')
const result = ref<{ created: number, skipped: LocationImportIssue[], errors: LocationImportIssue[], warnings: LocationImportIssue[] } | null>(null)

function reset() {
  fileName.value = ''
  csv.value = ''
  preview.value = null
  failure.value = ''
  result.value = null
}

watch(() => props.open, (open) => {
  if (open) reset()
})

async function onFile(event: Event) {
  const input = event.target as HTMLInputElement
  const file = input.files?.[0]
  input.value = ''
  if (!file) return
  reset()
  fileName.value = file.name
  try {
    csv.value = await file.text()
    preview.value = parseLocationImport(csv.value)
  }
  catch {
    failure.value = 'This file could not be read. Save it as CSV and try again.'
  }
}

const problems = computed(() => {
  const source = result.value ?? preview.value
  if (!source) return []
  const skipped = result.value?.skipped ?? []
  return [
    ...source.errors.map(item => ({ ...item, kind: 'Not imported' })),
    ...skipped.map(item => ({ ...item, kind: 'Skipped' })),
    ...source.warnings.map(item => ({ ...item, kind: 'Note' })),
  ].sort((a, b) => a.line - b.line)
})

const canImport = computed(() => Boolean(preview.value && !preview.value.fileError && preview.value.rows.length) && !result.value)

async function runImport() {
  if (!canImport.value || importing.value) return
  importing.value = true
  failure.value = ''
  try {
    result.value = await $fetch('/api/locations/import', { method: 'POST', body: { csv: csv.value } })
    if (result.value?.created) emit('imported')
  }
  catch (error) {
    failure.value = apiErrorMessage(error, 'The import did not finish. Nothing was added.')
  }
  finally {
    importing.value = false
  }
}

function downloadTemplate() {
  downloadTextFile(locationImportTemplate(), 'yard-link-locations-template.csv', 'text/csv;charset=utf-8')
}

function plural(count: number, word: string) {
  return `${count} ${word}${count === 1 ? '' : 's'}`
}
</script>

<template>
  <BottomSheet
    :open="open"
    title="Import locations"
    @close="emit('close')"
  >
    <div class="import-sheet">
      <p class="field-hint">
        Add many locations at once from a spreadsheet saved as CSV. Each row needs a Name and a Type. A location whose name you already have is left as it is.
      </p>

      <p
        v-if="failure"
        class="banner err"
        role="alert"
      >
        <span aria-hidden="true">✕</span>
        <span>{{ failure }}</span>
      </p>

      <template v-if="result">
        <p
          class="banner"
          :class="result.created ? 'ok' : 'info'"
          role="status"
        >
          <span aria-hidden="true">{{ result.created ? '✓' : 'i' }}</span>
          <span>
            <b>{{ plural(result.created, 'location') }} added.</b>
            <template v-if="result.skipped.length"> {{ plural(result.skipped.length, 'row') }} skipped because the name already exists.</template>
            <template v-if="result.errors.length"> {{ plural(result.errors.length, 'row') }} could not be imported.</template>
          </span>
        </p>
        <p
          v-if="result.created"
          class="field-hint"
        >
          Locations imported without a latitude and longitude have no map pin yet. Open a location and choose Edit to place it.
        </p>
      </template>

      <template v-else>
        <label class="import-file">
          <input
            type="file"
            accept=".csv,text/csv"
            class="sr-only"
            @change="onFile"
          >
          <span class="btn-dark w-auto">{{ fileName ? 'Choose a different file' : 'Choose a CSV file' }}</span>
          <span
            v-if="fileName"
            class="import-file-name"
          >{{ fileName }}</span>
        </label>

        <p
          v-if="preview?.fileError"
          class="banner err"
          role="alert"
        >
          <span aria-hidden="true">✕</span>
          <span>{{ preview.fileError }}</span>
        </p>
        <p
          v-else-if="preview"
          class="banner"
          :class="preview.rows.length ? 'ok' : 'warn'"
          role="status"
        >
          <span aria-hidden="true">{{ preview.rows.length ? '✓' : '!' }}</span>
          <span>
            <b>{{ plural(preview.rows.length, 'location') }} ready to import.</b>
            <template v-if="preview.errors.length"> {{ plural(preview.errors.length, 'row') }} cannot be imported.</template>
          </span>
        </p>
      </template>

      <div
        v-if="problems.length"
        class="import-problems"
      >
        <table class="dtable">
          <caption class="sr-only">
            Rows that need attention
          </caption>
          <thead>
            <tr>
              <th scope="col">
                Line
              </th>
              <th scope="col">
                Location
              </th>
              <th scope="col">
                What happened
              </th>
            </tr>
          </thead>
          <tbody>
            <tr
              v-for="(item, index) in problems"
              :key="`${item.line}-${index}`"
            >
              <td class="tabular-nums">
                {{ item.line }}
              </td>
              <td>{{ item.name || '—' }}</td>
              <td><b>{{ item.kind }}:</b> {{ item.message }}</td>
            </tr>
          </tbody>
        </table>
      </div>

      <button
        v-if="!result"
        type="button"
        class="import-template"
        @click="downloadTemplate"
      >
        Download a template with the column names
      </button>
    </div>

    <div class="sheet-actions">
      <button
        type="button"
        class="btn-cancel"
        :disabled="importing"
        @click="emit('close')"
      >
        {{ result ? 'Done' : 'Cancel' }}
      </button>
      <button
        v-if="!result"
        type="button"
        class="btn-save"
        :disabled="!canImport || importing"
        @click="runImport"
      >
        {{ importing ? 'Importing…' : preview?.rows.length ? `Import ${plural(preview.rows.length, 'location')}` : 'Import' }}
      </button>
    </div>
  </BottomSheet>
</template>
