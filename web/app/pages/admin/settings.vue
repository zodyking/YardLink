<script setup lang="ts">
/**
 * Company settings. Everything an employer configures is here — the server
 * needs no files edited and no restart for any of it.
 */
import { checkEmailSettings, emptyEmailSettings } from '#shared/utils/email-settings'

definePageMeta({ layout: 'admin' })
useHead({ title: 'Settings' })

interface SettingsPayload {
  company: { id: string, name: string, legalName: string | null, usdotNumber: string | null, timezone: string, inviteCode: string }
  settings: { publicUrl: string, shipcsxDefaultTerminal: string, shipcsxPoll: boolean, approveNewAccounts: boolean }
  email: { configured: boolean, host: string, port: number, user: string, fromName: string, fromEmail: string, hasPassword: boolean }
  push: { configured: boolean, keyId: string, teamId: string, bundleId: string, sandbox: boolean, hasKey: boolean }
  database: { source: 'builtin' | 'wizard' | 'env', external: boolean, label: string }
  shipcsxTerminals: string[]
  counts: { containers: number, activeContainers: number, locations: number, drivers: number, trucks: number, admins: number }
  services: Array<{ key: string, name: string, healthy: boolean, detail: string, phase: string }>
}
interface ConnectPayload {
  server: string
  usingConfiguredAddress: boolean
  isSecure: boolean
  companyName: string
  link: string
  qrSvg: string
  joinCode: string
}

const route = useRoute()
const { data, status, error, refresh } = await useFetch<SettingsPayload>('/api/admin/settings')
const { data: connect, refresh: refreshConnect } = await useFetch<ConnectPayload>('/api/admin/connect')

const welcome = ref(route.query.welcome === '1')

const form = reactive({
  name: '',
  legalName: '',
  usdotNumber: '',
  timezone: 'America/New_York',
  publicUrl: '',
  shipcsxDefaultTerminal: '',
  shipcsxPoll: false,
  approveNewAccounts: true,
})

/* Outgoing email has its own form: it is checked against the mail server
   before it is saved, and it can be tested and turned off. */
const emailForm = ref(emptyEmailSettings())
const emailErrors = ref<Record<string, string>>({})
const emailBusy = ref<'save' | 'test' | 'off' | null>(null)
const emailResult = ref<{ ok: boolean, message: string } | null>(null)
const confirmEmailOff = ref(false)

function emailBody() {
  return { ...emailForm.value, port: Number(emailForm.value.port) }
}

async function runEmail(action: 'save' | 'test' | 'off') {
  if (emailBusy.value) return
  emailResult.value = null
  if (action !== 'off') {
    emailErrors.value = checkEmailSettings(emailForm.value)
    if (Object.keys(emailErrors.value).length) return
  }
  emailBusy.value = action
  try {
    if (action === 'save') {
      await $fetch('/api/admin/email', { method: 'PUT', body: emailBody() })
      emailResult.value = { ok: true, message: 'Email settings saved. Yard Link signed in to the mail server successfully.' }
    }
    else if (action === 'test') {
      const result = await $fetch<{ message: string }>('/api/admin/email/test', { method: 'POST', body: { settings: emailBody() } })
      emailResult.value = { ok: true, message: `${result.message} Check that inbox.` }
    }
    else {
      await $fetch('/api/admin/email', { method: 'DELETE' })
      emailResult.value = { ok: true, message: 'Email is turned off.' }
    }
    if (action !== 'test') await refresh()
  }
  catch (err) {
    emailResult.value = { ok: false, message: apiErrorMessage(err, 'That did not work. Check the settings and try again.') }
  }
  finally {
    emailBusy.value = null
  }
}

async function turnEmailOff() {
  confirmEmailOff.value = false
  await runEmail('off')
}

/* Apple push: the signing key is pasted once and never comes back from the
   server, so an empty key field means "keep the one already saved". */
const pushForm = ref({ keyId: '', teamId: '', bundleId: '', signingKey: '', sandbox: false })
const pushBusy = ref<'save' | 'test' | 'off' | null>(null)
const pushResult = ref<{ ok: boolean, message: string } | null>(null)
const confirmPushOff = ref(false)

interface PushStatus {
  phones: Array<{ name: string, service: string, appVersion: string | null, lastSeenAt: string }>
  recent: Array<{ at: string, kind: string, outcome: 'sent' | 'off' | 'nobody' | 'failed', sent: number, detail: string }>
}
const { data: pushStatus, refresh: refreshPushStatus } = await useFetch<PushStatus>('/api/admin/push/status')
const OUTCOME_LABELS = { sent: 'Sent', off: 'Push is off', nobody: 'No phone', failed: 'Refused' } as const

async function runPush(action: 'save' | 'test' | 'off') {
  if (pushBusy.value) return
  pushResult.value = null
  pushBusy.value = action
  try {
    if (action === 'save') {
      await $fetch('/api/admin/push', { method: 'PUT', body: { ...pushForm.value } })
      pushForm.value.signingKey = ''
      pushResult.value = { ok: true, message: 'Push settings saved. Send yourself a test to check them.' }
    }
    else if (action === 'test') {
      const result = await $fetch<{ message: string }>('/api/admin/push/test', { method: 'POST' })
      pushResult.value = { ok: true, message: result.message }
      await refreshPushStatus()
    }
    else {
      await $fetch('/api/admin/push', { method: 'DELETE' })
      pushResult.value = { ok: true, message: 'Push notifications are off.' }
    }
    if (action !== 'test') await refresh()
  }
  catch (err) {
    pushResult.value = { ok: false, message: apiErrorMessage(err, 'That did not work. Check the key and try again.') }
  }
  finally {
    pushBusy.value = null
  }
}

async function turnPushOff() {
  confirmPushOff.value = false
  await runPush('off')
}

function fill() {
  if (!data.value) return
  emailForm.value = {
    host: data.value.email.host,
    port: data.value.email.port,
    user: data.value.email.user,
    password: '',
    fromName: data.value.email.fromName,
    fromEmail: data.value.email.fromEmail,
  }
  pushForm.value = {
    keyId: data.value.push.keyId,
    teamId: data.value.push.teamId,
    bundleId: data.value.push.bundleId,
    signingKey: '',
    sandbox: data.value.push.sandbox,
  }
  form.name = data.value.company.name
  form.legalName = data.value.company.legalName ?? ''
  form.usdotNumber = data.value.company.usdotNumber ?? ''
  form.timezone = data.value.company.timezone
  form.publicUrl = data.value.settings.publicUrl
  form.shipcsxDefaultTerminal = data.value.settings.shipcsxDefaultTerminal
  form.shipcsxPoll = data.value.settings.shipcsxPoll
  form.approveNewAccounts = data.value.settings.approveNewAccounts
}
watch(data, fill, { immediate: true })

const timezones = computed(() => {
  const common = ['America/New_York', 'America/Chicago', 'America/Denver', 'America/Phoenix', 'America/Los_Angeles', 'America/Anchorage', 'Pacific/Honolulu', 'America/Puerto_Rico']
  return common.includes(form.timezone) ? common : [form.timezone, ...common]
})

const saving = ref<string | null>(null)
const saved = ref<string | null>(null)
const saveError = ref('')
let savedTimer: ReturnType<typeof setTimeout> | undefined

async function save(section: string, body: Record<string, unknown>) {
  if (saving.value) return
  saving.value = section
  saveError.value = ''
  saved.value = null
  try {
    await $fetch('/api/admin/settings', { method: 'PATCH', body })
    await Promise.all([refresh(), refreshConnect()])
    saved.value = section
    if (savedTimer) clearTimeout(savedTimer)
    savedTimer = setTimeout(() => {
      saved.value = null
    }, 2500)
  }
  catch (err) {
    saveError.value = apiErrorMessage(err, 'Could not save. Check the fields and try again.')
  }
  finally {
    saving.value = null
  }
}

const saveProfile = () => save('profile', {
  name: form.name,
  legalName: form.legalName,
  usdotNumber: form.usdotNumber,
  timezone: form.timezone,
})
const saveAddress = () => save('address', { publicUrl: form.publicUrl })
const saveAccounts = () => save('accounts', { approveNewAccounts: form.approveNewAccounts })
const saveShipcsx = () => save('shipcsx', {
  shipcsxDefaultTerminal: form.shipcsxDefaultTerminal,
  shipcsxPoll: form.shipcsxPoll,
})

const confirmNewCode = ref(false)
async function newJoinCode() {
  confirmNewCode.value = false
  await save('code', { newJoinCode: true })
}

const copied = ref(false)
async function copyJoinCode() {
  if (!connect.value) return
  try {
    await navigator.clipboard.writeText(connect.value.joinCode)
    copied.value = true
    setTimeout(() => {
      copied.value = false
    }, 2000)
  }
  catch {
    copied.value = false
  }
}

function printCode() {
  window.print()
}

onBeforeUnmount(() => {
  if (savedTimer) clearTimeout(savedTimer)
})

const countCards = computed(() => {
  const counts = data.value?.counts
  if (!counts) return []
  return [
    { label: 'Containers', value: counts.containers },
    { label: 'In the active pool', value: counts.activeContainers },
    { label: 'Locations', value: counts.locations },
    { label: 'Drivers', value: counts.drivers },
    { label: 'Dispatchers', value: counts.admins },
    { label: 'Trucks', value: counts.trucks },
  ]
})
</script>

<template>
  <div class="settings-page">
    <div class="a-head">
      <div>
        <span class="eyebrow">Company</span>
        <h1>Settings</h1>
        <p class="a-head-copy">
          Everything about this Yard Link server is managed here.
        </p>
      </div>
    </div>

    <p
      v-if="welcome"
      class="banner ok"
      role="status"
    >
      <span aria-hidden="true">✓</span>
      <span>
        <b>Yard Link is set up.</b>
        Show the code below to your drivers so they can connect the iPhone app, and give them the join code to create their accounts.
      </span>
      <button
        class="btn-ghost ml-auto"
        type="button"
        @click="welcome = false"
      >
        Got it
      </button>
    </p>

    <div
      v-if="status === 'pending' && !data"
      class="card p-5"
      role="status"
    >
      Loading settings…
    </div>

    <div
      v-else-if="error"
      class="banner err"
      role="alert"
    >
      <span aria-hidden="true">✕</span>
      <span>
        <b>Could not load settings</b>
        {{ apiErrorMessage(error) }}
      </span>
      <button
        class="btn-ghost ml-auto"
        @click="refresh()"
      >
        Try again
      </button>
    </div>

    <template v-else-if="data">
      <p
        v-if="saveError"
        class="banner err"
        role="alert"
      >
        <span aria-hidden="true">✕</span>
        <span>{{ saveError }}</span>
      </p>

      <!-- ── Connect phones ─────────────────────────────────────── -->
      <div class="section-label">
        <span>Connect to your employer</span>
      </div>
      <section
        v-if="connect"
        class="card connect-card"
      >
        <div
          class="connect-qr"
          role="img"
          :aria-label="`Connection code for ${connect.companyName}`"
          v-html="connect.qrSvg"
        />
        <div class="connect-copy">
          <h2>{{ connect.companyName }}</h2>
          <ol>
            <li>Open Yard Link on the iPhone.</li>
            <li>On <b>Connect to Your Employer</b>, scan this code.</li>
            <li>Create an account with the join code, or sign in.</li>
          </ol>
          <p class="connect-server">
            <span class="eyebrow">Server address in the code</span>
            <code class="mono">{{ connect.server }}</code>
          </p>
          <p
            v-if="!connect.isSecure"
            class="banner warn"
          >
            <span aria-hidden="true">!</span>
            <span>This address is not https. iPhones only connect to http addresses on the same local network. For use on the road, put this server behind an https address and enter it below.</span>
          </p>
          <p class="field-hint">
            The code holds only the server address and company name — no password and no join code.
          </p>
          <div class="connect-join">
            <div>
              <span class="eyebrow">Join code</span>
              <code class="mono connect-code">{{ connect.joinCode }}</code>
            </div>
            <button
              class="btn-ghost"
              type="button"
              @click="copyJoinCode"
            >
              {{ copied ? 'Copied' : 'Copy' }}
            </button>
            <button
              class="btn-ghost"
              type="button"
              :disabled="saving === 'code'"
              @click="confirmNewCode = true"
            >
              New code
            </button>
            <button
              class="btn-ghost connect-print"
              type="button"
              @click="printCode"
            >
              Print
            </button>
          </div>
        </div>
      </section>

      <section class="card p-5 settings-form">
        <label class="field">
          <span>Server address for phones</span>
          <input
            v-model="form.publicUrl"
            class="input mono"
            inputmode="url"
            autocapitalize="off"
            spellcheck="false"
            placeholder="https://yard.yourcompany.com"
          >
          <small class="field-hint">
            The address drivers' phones use to reach this server. Leave it empty to use the address you are on now.
          </small>
        </label>
        <button
          class="btn-primary-action settings-save"
          type="button"
          :disabled="saving === 'address'"
          @click="saveAddress"
        >
          {{ saving === 'address' ? 'Saving…' : saved === 'address' ? 'Saved' : 'Save address' }}
        </button>
      </section>

      <!-- ── Company profile ─────────────────────────────────────── -->
      <div class="section-label">
        <span>Company profile</span>
      </div>
      <form
        class="card p-5 settings-form"
        @submit.prevent="saveProfile"
      >
        <div class="settings-grid">
          <label class="field">
            <span>Company name</span>
            <input
              v-model="form.name"
              class="input"
              required
              maxlength="120"
            >
          </label>
          <label class="field">
            <span>Legal name</span>
            <input
              v-model="form.legalName"
              class="input"
              maxlength="160"
            >
          </label>
          <label class="field">
            <span>USDOT number</span>
            <input
              v-model="form.usdotNumber"
              class="input mono"
              inputmode="numeric"
              maxlength="20"
            >
          </label>
          <label class="field">
            <span>Timezone</span>
            <select
              v-model="form.timezone"
              class="input"
            >
              <option
                v-for="zone in timezones"
                :key="zone"
                :value="zone"
              >
                {{ zone.replace(/_/g, ' ') }}
              </option>
            </select>
            <small class="field-hint">Work dates, time cards and task days follow this.</small>
          </label>
        </div>
        <button
          class="btn-primary-action settings-save"
          type="submit"
          :disabled="saving === 'profile'"
        >
          {{ saving === 'profile' ? 'Saving…' : saved === 'profile' ? 'Saved' : 'Save profile' }}
        </button>
      </form>

      <!-- ── Accounts ────────────────────────────────────────────── -->
      <div class="section-label">
        <span>New accounts</span>
      </div>
      <section class="card p-5 settings-form">
        <label class="yl-switch-row">
          <span>
            <b>A dispatcher approves each new account</b>
            <small>People who sign up with the join code wait under Drivers until approved. Turn this off to let them in straight away.</small>
          </span>
          <input
            v-model="form.approveNewAccounts"
            class="yl-switch"
            type="checkbox"
            @change="saveAccounts"
          >
        </label>
      </section>

      <!-- ── Email ───────────────────────────────────────────────── -->
      <div class="section-label">
        <span>Email</span>
      </div>
      <form
        class="card p-5 settings-form"
        novalidate
        @submit.prevent="runEmail('save')"
      >
        <div class="settings-status">
          <StatusChip
            :variant="data.email.configured ? 'ok' : 'idle'"
            :label="data.email.configured ? 'Email is on' : 'Email is off'"
          />
          <span>
            {{ data.email.configured
              ? 'New people get a welcome email and confirm their address. Anyone can choose to get work assignments and messages by email in their own settings.'
              : 'Yard Link sends no email. Enter the settings from your email provider to turn it on.' }}
          </span>
        </div>

        <EmailSettingsFields
          v-model="emailForm"
          :errors="emailErrors"
          :has-password="data.email.hasPassword"
          :company-name="data.company.name"
        />

        <p
          v-if="emailResult"
          class="banner"
          :class="emailResult.ok ? 'ok' : 'err'"
          :role="emailResult.ok ? 'status' : 'alert'"
        >
          <span aria-hidden="true">{{ emailResult.ok ? '✓' : '✕' }}</span>
          <span>{{ emailResult.message }}</span>
        </p>

        <div class="settings-actions">
          <button
            class="btn-primary-action settings-save"
            type="submit"
            :disabled="emailBusy !== null"
          >
            {{ emailBusy === 'save' ? 'Checking…' : 'Save email settings' }}
          </button>
          <button
            class="btn-ghost"
            type="button"
            :disabled="emailBusy !== null"
            @click="runEmail('test')"
          >
            {{ emailBusy === 'test' ? 'Sending…' : 'Send me a test email' }}
          </button>
          <button
            v-if="data.email.configured"
            class="btn-ghost"
            type="button"
            :disabled="emailBusy !== null"
            @click="confirmEmailOff = true"
          >
            Turn email off
          </button>
        </div>
      </form>

      <!-- ── Push notifications ──────────────────────────────────── -->
      <div class="section-label">
        <span>Push notifications</span>
      </div>
      <form
        class="card p-5 settings-form"
        novalidate
        @submit.prevent="runPush('save')"
      >
        <div class="settings-status">
          <StatusChip
            :variant="data.push.configured ? 'ok' : 'idle'"
            :label="data.push.configured ? 'Push is on' : 'Push is off'"
          />
          <span>
            {{ data.push.configured
              ? 'Phones are told about new messages and new work straight away, even when the app is closed.'
              : 'Phones find new messages and work when the app is opened. Paste the key from your Apple Developer account to send notices instead.' }}
          </span>
        </div>

        <div class="settings-grid">
          <label class="field">
            <span>Key ID</span>
            <input
              v-model.trim="pushForm.keyId"
              class="input mono"
              autocapitalize="characters"
              autocomplete="off"
              spellcheck="false"
              placeholder="ABCD123456"
              maxlength="20"
            >
            <small class="field-hint">Apple Developer → Keys. The ten characters beside the key you made for APNs.</small>
          </label>

          <label class="field">
            <span>Team ID</span>
            <input
              v-model.trim="pushForm.teamId"
              class="input mono"
              autocapitalize="characters"
              autocomplete="off"
              spellcheck="false"
              placeholder="A1B2C3D4E5"
              maxlength="20"
            >
            <small class="field-hint">Apple Developer → Membership details.</small>
          </label>

          <label class="field settings-wide">
            <span>App bundle identifier</span>
            <input
              v-model.trim="pushForm.bundleId"
              class="input mono"
              autocapitalize="off"
              autocomplete="off"
              spellcheck="false"
              placeholder="com.yourcompany.yardlink"
              maxlength="200"
            >
            <small class="field-hint">The same identifier the iPhone app is built with.</small>
          </label>

          <label class="field settings-wide">
            <span>Signing key (.p8)</span>
            <textarea
              v-model="pushForm.signingKey"
              class="input mono settings-key"
              rows="5"
              autocapitalize="off"
              autocomplete="off"
              spellcheck="false"
              :placeholder="data.push.hasKey ? 'A key is saved. Paste a new one only to replace it.' : '-----BEGIN PRIVATE KEY-----'"
              maxlength="4000"
            />
            <small class="field-hint">
              {{ data.push.hasKey
                ? 'A key is saved. Leave this empty to keep it.'
                : 'Open the AuthKey_XXXXXXXXXX.p8 file Apple gave you in a text editor and paste the whole thing, BEGIN and END lines included.' }}
            </small>
          </label>
        </div>

        <label class="yl-switch-row">
          <span>
            <b>This build is signed for development</b>
            <small>Turn on while testing a build from Xcode. TestFlight and App Store builds need this off.</small>
          </span>
          <input
            v-model="pushForm.sandbox"
            class="yl-switch"
            type="checkbox"
          >
        </label>

        <div class="settings-status">
          <StatusChip
            :variant="pushStatus?.phones.length ? 'ok' : 'warn'"
            :label="pushStatus?.phones.length ? `${pushStatus.phones.length} ${pushStatus.phones.length === 1 ? 'phone' : 'phones'} signed in` : 'No phones signed in'"
          />
          <span v-if="!pushStatus?.phones.length">
            A phone appears here after someone signs in on the iPhone app and allows notifications.
          </span>
          <ul
            v-else
            class="settings-list"
          >
            <li
              v-for="(phone, index) in pushStatus.phones"
              :key="index"
            >
              {{ phone.name }} · {{ phone.service }} build{{ phone.appVersion ? ` ${phone.appVersion}` : '' }}
            </li>
          </ul>
        </div>

        <div
          v-if="pushStatus?.recent.length"
          class="settings-status"
        >
          <span><strong>Recent notices</strong> (cleared when the server restarts)</span>
          <ul class="settings-list">
            <li
              v-for="entry in pushStatus.recent"
              :key="entry.at + entry.kind"
            >
              {{ new Date(entry.at).toLocaleTimeString() }} · {{ entry.kind }} · {{ OUTCOME_LABELS[entry.outcome] }}: {{ entry.detail }}
            </li>
          </ul>
        </div>

        <p
          v-if="pushResult"
          class="banner"
          :class="pushResult.ok ? 'ok' : 'err'"
          :role="pushResult.ok ? 'status' : 'alert'"
        >
          <span aria-hidden="true">{{ pushResult.ok ? '✓' : '✕' }}</span>
          <span>{{ pushResult.message }}</span>
        </p>

        <div class="settings-actions">
          <button
            class="btn-primary-action settings-save"
            type="submit"
            :disabled="pushBusy !== null"
          >
            {{ pushBusy === 'save' ? 'Saving…' : 'Save push settings' }}
          </button>
          <button
            v-if="data.push.configured"
            class="btn-ghost"
            type="button"
            :disabled="pushBusy !== null"
            @click="runPush('test')"
          >
            {{ pushBusy === 'test' ? 'Sending…' : 'Send me a test notice' }}
          </button>
          <button
            v-if="data.push.configured"
            class="btn-ghost"
            type="button"
            :disabled="pushBusy !== null"
            @click="confirmPushOff = true"
          >
            Turn push off
          </button>
        </div>
      </form>

      <!-- ── Database ────────────────────────────────────────────── -->
      <div class="section-label">
        <span>Database</span>
      </div>
      <section class="card p-5 settings-form">
        <div class="settings-status">
          <StatusChip
            :variant="data.database.external ? 'ok' : 'warn'"
            :label="data.database.external ? 'Your own database' : 'Built-in database'"
          />
          <span
            v-if="data.database.external"
            class="mono setup-break"
          >{{ data.database.label }}</span>
        </div>
        <p
          v-if="data.database.external"
          class="field-hint"
        >
          Your records are kept outside Yard Link, so they stay when Yard Link is updated or redeployed. Back this database up with your database provider.
        </p>
        <p
          v-else
          class="banner warn"
        >
          <span aria-hidden="true">!</span>
          <span>
            <b>Your data can be deleted on any update or redeployment.</b>
            Records are kept inside this installation. To keep them safe, install Yard Link again with your own PostgreSQL database chosen in the setup wizard. Records in the built-in database are not moved for you.
          </span>
        </p>
      </section>

      <!-- ── ShipCSX ─────────────────────────────────────────────── -->
      <div class="section-label">
        <span>ShipCSX</span>
      </div>
      <section class="card p-5 settings-form">
        <div class="settings-grid">
          <label class="field">
            <span>Default terminal</span>
            <select
              v-model="form.shipcsxDefaultTerminal"
              class="input"
            >
              <option value="">
                None
              </option>
              <option
                v-for="terminal in data.shipcsxTerminals"
                :key="terminal"
                :value="terminal"
              >
                {{ terminal }}
              </option>
            </select>
            <small class="field-hint">Used when a container is not headed to a rail yard with its own terminal.</small>
          </label>
        </div>
        <label class="yl-switch-row">
          <span>
            <b>Check ShipCSX automatically</b>
            <small>Every 30 minutes between 5am and 10pm Eastern, for containers at customers.</small>
          </span>
          <input
            v-model="form.shipcsxPoll"
            class="yl-switch"
            type="checkbox"
          >
        </label>
        <button
          class="btn-primary-action settings-save"
          type="button"
          :disabled="saving === 'shipcsx'"
          @click="saveShipcsx"
        >
          {{ saving === 'shipcsx' ? 'Saving…' : saved === 'shipcsx' ? 'Saved' : 'Save ShipCSX' }}
        </button>
      </section>

      <!-- ── Records ─────────────────────────────────────────────── -->
      <div class="section-label">
        <span>Records</span>
      </div>
      <section class="settings-counts">
        <div
          v-for="card in countCards"
          :key="card.label"
          class="card"
        >
          <b class="mono">{{ card.value }}</b>
          <span>{{ card.label }}</span>
        </div>
      </section>

      <!-- ── System ──────────────────────────────────────────────── -->
      <div class="section-label">
        <span>System</span>
      </div>
      <section class="card overflow-x-auto">
        <table class="dtable">
          <caption class="sr-only">
            Status of each part of this Yard Link server
          </caption>
          <thead>
            <tr>
              <th scope="col">
                Part
              </th>
              <th scope="col">
                Status
              </th>
              <th scope="col">
                Detail
              </th>
            </tr>
          </thead>
          <tbody>
            <tr
              v-for="service in data.services"
              :key="service.key"
            >
              <td>{{ service.name }}</td>
              <td>
                <StatusChip
                  :variant="service.healthy ? 'ok' : 'idle'"
                  :label="service.healthy ? 'Working' : 'Not in use'"
                />
              </td>
              <td class="text-sm text-[var(--color-ink-500)]">
                {{ service.detail }}
              </td>
            </tr>
          </tbody>
        </table>
      </section>
    </template>

    <BottomSheet
      :open="confirmEmailOff"
      title="Turn email off?"
      @close="confirmEmailOff = false"
    >
      <p class="px-4 pb-2 text-sm">
        Yard Link stops sending email and forgets these settings. New accounts will no longer confirm an address. Work and messages still reach everyone inside Yard Link.
      </p>
      <div class="sheet-actions">
        <button
          type="button"
          class="btn-cancel"
          @click="confirmEmailOff = false"
        >
          Keep email on
        </button>
        <button
          type="button"
          class="btn-save"
          @click="turnEmailOff"
        >
          Turn email off
        </button>
      </div>
    </BottomSheet>

    <BottomSheet
      :open="confirmPushOff"
      title="Turn push notifications off?"
      @close="confirmPushOff = false"
    >
      <p class="px-4 pb-2 text-sm">
        Yard Link forgets the Apple key and stops sending notices. Phones will find new messages and work the next time the app is opened.
      </p>
      <div class="sheet-actions">
        <button
          type="button"
          class="btn-cancel"
          @click="confirmPushOff = false"
        >
          Keep push on
        </button>
        <button
          type="button"
          class="btn-save"
          @click="turnPushOff"
        >
          Turn push off
        </button>
      </div>
    </BottomSheet>

    <BottomSheet
      :open="confirmNewCode"
      title="Make a new join code?"
      @close="confirmNewCode = false"
    >
      <p class="px-4 pb-2 text-sm">
        The current code stops working for new sign-ups. People who already have accounts are not affected.
      </p>
      <div class="sheet-actions">
        <button
          type="button"
          class="btn-cancel"
          @click="confirmNewCode = false"
        >
          Keep current code
        </button>
        <button
          type="button"
          class="btn-save"
          @click="newJoinCode"
        >
          Make new code
        </button>
      </div>
    </BottomSheet>
  </div>
</template>
