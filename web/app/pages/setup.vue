<script setup lang="ts">
/**
 * First-run setup. Shown once, the first time someone opens a new Yard Link
 * server: choose the database, name the company, create the first dispatcher,
 * set up email, confirm the address phones will use. After that everything is
 * changed under Settings.
 *
 * The database is applied as soon as its step is passed, because every later
 * answer is saved into it. The rest is saved together at the end.
 */
import { checkDatabaseUrl } from '#shared/utils/database-url'
import { checkEmailSettings, emptyEmailSettings } from '#shared/utils/email-settings'

definePageMeta({ layout: 'auth' })
useHead({ title: 'Set up Yard Link' })

interface DatabaseStatus { source: 'builtin' | 'wizard' | 'env', external: boolean, label: string }

const { fetch: refreshSession } = useUserSession()
const needsSetup = useState<boolean | null>('needs-setup', () => null)

const steps = [
  { key: 'database', label: 'Database' },
  { key: 'company', label: 'Company' },
  { key: 'account', label: 'Account' },
  { key: 'email', label: 'Email' },
  { key: 'phones', label: 'Phones' },
  { key: 'finish', label: 'Finish' },
] as const
type StepKey = (typeof steps)[number]['key']

const step = ref(0)
const current = computed<StepKey>(() => steps[step.value]!.key)

const guessedZone = (() => {
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone || 'America/New_York'
  }
  catch {
    return 'America/New_York'
  }
})()

const form = reactive({
  company: { name: '', legalName: '', usdotNumber: '', timezone: guessedZone },
  admin: { firstName: '', lastName: '', email: '', mobileNumber: '', password: '', confirm: '' },
  publicUrl: '',
})

const errors = ref<Record<string, string>>({})
const submitting = ref(false)
const failure = ref('')

/* ── Database ─────────────────────────────────────────────────────── */
const { data: status } = await useFetch<{ needsSetup: boolean, database: DatabaseStatus }>('/api/setup/status')
const database = ref<DatabaseStatus | null>(status.value?.database ?? null)

/** `external`: paste a connection string. `builtin`: skip and accept the risk. */
const databaseChoice = ref<'external' | 'builtin'>('external')
const databaseUrl = ref('')
const acceptsBuiltinRisk = ref(false)
/** An external database is already in use, so there is nothing to enter. */
const databaseReady = computed(() => Boolean(database.value?.external))
const changingDatabase = ref(false)
const showDatabaseForm = computed(() => !databaseReady.value || changingDatabase.value)

function changeDatabase() {
  databaseChoice.value = 'external'
  changingDatabase.value = true
}

async function applyDatabase(): Promise<boolean> {
  if (!showDatabaseForm.value) return true
  if (databaseChoice.value === 'builtin') {
    if (!acceptsBuiltinRisk.value) {
      errors.value = { databaseRisk: 'Tick the box to continue without an external database.' }
      return false
    }
    return true
  }

  const check = checkDatabaseUrl(databaseUrl.value)
  if (!check.ok) {
    errors.value = { databaseUrl: check.message }
    return false
  }

  submitting.value = true
  try {
    const result = await $fetch<{ needsSetup: boolean, database: DatabaseStatus }>('/api/setup/database', {
      method: 'POST',
      body: { url: check.url },
    })
    database.value = result.database
    changingDatabase.value = false
    databaseUrl.value = ''
    if (!result.needsSetup) {
      // This database already holds a Yard Link company: nothing to set up.
      needsSetup.value = false
      await navigateTo({ path: '/login', query: { restored: '1' } }, { replace: true })
      return false
    }
    return true
  }
  catch (error) {
    errors.value = { databaseUrl: apiErrorMessage(error, 'That database could not be used. Check the connection string and try again.') }
    return false
  }
  finally {
    submitting.value = false
  }
}

/* ── Email ────────────────────────────────────────────────────────── */
const emailChoice = ref<'setup' | 'skip'>('setup')
const email = ref(emptyEmailSettings())
const testing = ref(false)
const testResult = ref<{ ok: boolean, message: string } | null>(null)

function emailBody() {
  return { ...email.value, port: Number(email.value.port) }
}

async function sendTest() {
  if (testing.value) return
  errors.value = checkEmailSettings(email.value)
  testResult.value = null
  if (Object.keys(errors.value).length) return
  testing.value = true
  try {
    const result = await $fetch<{ message: string }>('/api/setup/email-test', {
      method: 'POST',
      body: { settings: emailBody(), to: form.admin.email.trim(), companyName: form.company.name },
    })
    testResult.value = { ok: true, message: `${result.message} Check that inbox.` }
  }
  catch (error) {
    testResult.value = { ok: false, message: apiErrorMessage(error, 'The test email could not be sent.') }
  }
  finally {
    testing.value = false
  }
}

onMounted(() => {
  if (!form.publicUrl) form.publicUrl = window.location.origin
})

const timezones = computed(() => {
  const common = ['America/New_York', 'America/Chicago', 'America/Denver', 'America/Phoenix', 'America/Los_Angeles', 'America/Anchorage', 'Pacific/Honolulu', 'America/Puerto_Rico']
  return common.includes(form.company.timezone) ? common : [form.company.timezone, ...common]
})

const isLocalHttp = computed(() => /^http:\/\//i.test(form.publicUrl.trim()))

function validate(key: StepKey): boolean {
  const next: Record<string, string> = {}
  if (key === 'company') {
    if (!form.company.name.trim()) next.companyName = 'Enter the company name.'
  }
  if (key === 'account') {
    if (!form.admin.firstName.trim()) next.firstName = 'Enter your first name.'
    if (!form.admin.lastName.trim()) next.lastName = 'Enter your last name.'
    if (!/^\S+@\S+\.\S+$/.test(form.admin.email.trim())) next.email = 'Enter a valid email address.'
    if (form.admin.password.length < 10) next.password = 'Use at least 10 characters.'
    else if (form.admin.password !== form.admin.confirm) next.confirm = 'The two passwords do not match.'
    const digits = form.admin.mobileNumber.replace(/\D/g, '')
    if (digits && digits.length !== 10 && !(digits.length === 11 && digits.startsWith('1'))) {
      next.mobileNumber = 'Enter a 10-digit mobile number, or leave it empty.'
    }
  }
  if (key === 'email' && emailChoice.value === 'setup') {
    Object.assign(next, checkEmailSettings(email.value))
  }
  if (key === 'phones') {
    const value = form.publicUrl.trim()
    if (value && !/^https?:\/\/[^\s/]+/i.test(value)) next.publicUrl = 'Start with https:// — for example https://yard.yourcompany.com'
  }
  errors.value = next
  return Object.keys(next).length === 0
}

async function forward() {
  if (submitting.value) return
  failure.value = ''
  errors.value = {}
  if (current.value === 'database') {
    if (!(await applyDatabase())) return
  }
  else if (!validate(current.value)) {
    return
  }
  step.value = Math.min(step.value + 1, steps.length - 1)
}

function backward() {
  errors.value = {}
  failure.value = ''
  step.value = Math.max(step.value - 1, 0)
}

function goTo(key: StepKey) {
  step.value = steps.findIndex(item => item.key === key)
}

async function finish() {
  if (submitting.value) return
  for (const key of ['company', 'account', 'email', 'phones'] as const) {
    if (!validate(key)) {
      goTo(key)
      return
    }
  }
  submitting.value = true
  failure.value = ''
  try {
    const result = await $fetch<{ redirectTo: string }>('/api/setup', {
      method: 'POST',
      body: {
        company: form.company,
        admin: {
          firstName: form.admin.firstName,
          lastName: form.admin.lastName,
          email: form.admin.email,
          mobileNumber: form.admin.mobileNumber,
          password: form.admin.password,
        },
        publicUrl: form.publicUrl,
        email: emailChoice.value === 'setup' ? emailBody() : undefined,
      },
    })
    needsSetup.value = false
    await refreshSession()
    await navigateTo(result.redirectTo, { replace: true })
  }
  catch (error) {
    const failedStep = (error as { data?: { data?: { step?: string } } }).data?.data?.step
    if (failedStep === 'email') goTo('email')
    failure.value = apiErrorMessage(error, 'Setup could not be saved. Check your entries and try again.')
  }
  finally {
    submitting.value = false
  }
}

const databaseSummary = computed(() => {
  if (database.value?.external) return database.value.label
  return 'Built-in database on this server'
})
const emailSummary = computed(() => {
  if (emailChoice.value === 'skip') return 'Not set up'
  return `${email.value.fromEmail || email.value.user} through ${email.value.host}`
})
const continueLabel = computed(() => {
  if (current.value === 'finish') return submitting.value ? 'Setting up…' : 'Finish setup'
  if (current.value === 'database' && submitting.value) return 'Connecting…'
  return 'Continue'
})
</script>

<template>
  <div>
    <div class="auth-logo">
      <BrandLogo />
    </div>

    <AuthHeader
      title="Set up Yard Link"
      :subtitle="`Step ${step + 1} of ${steps.length}`"
    />

    <ol
      class="setup-steps"
      aria-label="Setup progress"
    >
      <li
        v-for="(item, index) in steps"
        :key="item.key"
        :class="{ on: index === step, done: index < step }"
        :aria-current="index === step ? 'step' : undefined"
      >
        <b>{{ index + 1 }}</b>
        <span>{{ item.label }}</span>
      </li>
    </ol>

    <form
      class="card p-4"
      novalidate
      @submit.prevent="current === 'finish' ? finish() : forward()"
    >
      <p
        v-if="failure"
        class="banner err"
        role="alert"
      >
        <span aria-hidden="true">✕</span>
        <span>{{ failure }}</span>
      </p>

      <!-- 1. Database -->
      <template v-if="current === 'database'">
        <h2 class="setup-title">
          Where should your records be kept?
        </h2>

        <template v-if="!showDatabaseForm && database">
          <p
            class="banner ok"
            role="status"
          >
            <span aria-hidden="true">✓</span>
            <span>
              <b>Connected to your database</b>
              <span class="mono setup-break">{{ database.label }}</span>
            </span>
          </p>
          <p class="field-hint">
            Your records are kept in this database, outside Yard Link, so they stay when Yard Link is updated or redeployed.
          </p>
          <button
            v-if="database.source === 'wizard'"
            class="btn-ghost setup-inline"
            type="button"
            @click="changeDatabase"
          >
            Use a different database
          </button>
        </template>

        <template v-else>
          <p class="field-hint mb-3">
            Yard Link keeps trips, equipment history and accounts in a PostgreSQL database. Connect your own so your records are safe when Yard Link is updated.
          </p>
          <div
            v-if="!databaseReady"
            class="signup-roles"
            role="radiogroup"
            aria-label="Database"
          >
            <button
              type="button"
              class="signup-role"
              role="radio"
              :aria-checked="databaseChoice === 'external'"
              :aria-pressed="databaseChoice === 'external'"
              @click="databaseChoice = 'external'"
            >
              <b>My own database</b>
            </button>
            <button
              type="button"
              class="signup-role"
              role="radio"
              :aria-checked="databaseChoice === 'builtin'"
              :aria-pressed="databaseChoice === 'builtin'"
              @click="databaseChoice = 'builtin'"
            >
              <b>Skip for now</b>
            </button>
          </div>

          <template v-if="databaseChoice === 'external'">
            <label class="field">
              <span>PostgreSQL connection string</span>
              <input
                v-model.trim="databaseUrl"
                class="input mono"
                :class="{ invalid: errors.databaseUrl }"
                autocomplete="off"
                autocapitalize="off"
                spellcheck="false"
                placeholder="postgresql://user:password@host:5432/database"
              >
              <small class="field-hint">
                Your database provider shows this as the connection string or connection URL. Use an empty database made for Yard Link. If the provider requires SSL, end the string with <code class="mono">?sslmode=require</code>
              </small>
              <small
                v-if="errors.databaseUrl"
                class="field-error"
                role="alert"
              >{{ errors.databaseUrl }}</small>
            </label>
            <p class="field-hint">
              Continue checks the connection and creates the Yard Link tables. A database that already holds your Yard Link records is reconnected with everything in place.
            </p>
            <button
              v-if="databaseReady"
              class="btn-ghost setup-inline"
              type="button"
              @click="changingDatabase = false"
            >
              Keep the current database
            </button>
          </template>

          <template v-else>
            <p
              class="banner warn"
              role="alert"
            >
              <span aria-hidden="true">!</span>
              <span>
                <b>Your data can be deleted on any update or redeployment.</b>
                Without your own database, records are kept inside this installation. Updating or redeploying Yard Link replaces the installation, and trips, equipment history, accounts and settings go with it. Use this only to try Yard Link.
              </span>
            </p>
            <label class="setup-check">
              <input
                v-model="acceptsBuiltinRisk"
                type="checkbox"
              >
              <span>I understand that my data can be deleted when Yard Link is updated or redeployed.</span>
            </label>
            <small
              v-if="errors.databaseRisk"
              class="field-error"
              role="alert"
            >{{ errors.databaseRisk }}</small>
          </template>
        </template>
      </template>

      <!-- 2. Company -->
      <template v-else-if="current === 'company'">
        <label class="field">
          <span>Company name</span>
          <input
            v-model="form.company.name"
            class="input"
            :class="{ invalid: errors.companyName }"
            autocomplete="organization"
            maxlength="120"
            required
          >
          <small class="field-hint">Drivers see this name when they connect.</small>
          <small
            v-if="errors.companyName"
            class="field-error"
          >{{ errors.companyName }}</small>
        </label>
        <label class="field">
          <span>Legal name (optional)</span>
          <input
            v-model="form.company.legalName"
            class="input"
            maxlength="160"
          >
        </label>
        <label class="field">
          <span>USDOT number (optional)</span>
          <input
            v-model="form.company.usdotNumber"
            class="input mono"
            inputmode="numeric"
            maxlength="20"
          >
        </label>
        <label class="field">
          <span>Timezone</span>
          <select
            v-model="form.company.timezone"
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
          <small class="field-hint">Work dates and time cards follow this.</small>
        </label>
      </template>

      <!-- 3. First dispatcher -->
      <template v-else-if="current === 'account'">
        <p class="field-hint mb-3">
          This is the first dispatcher account. You will use it to sign in and to approve everyone else.
        </p>
        <label class="field">
          <span>First name</span>
          <input
            v-model="form.admin.firstName"
            class="input"
            :class="{ invalid: errors.firstName }"
            autocomplete="given-name"
            required
          >
          <small
            v-if="errors.firstName"
            class="field-error"
          >{{ errors.firstName }}</small>
        </label>
        <label class="field">
          <span>Last name</span>
          <input
            v-model="form.admin.lastName"
            class="input"
            :class="{ invalid: errors.lastName }"
            autocomplete="family-name"
            required
          >
          <small
            v-if="errors.lastName"
            class="field-error"
          >{{ errors.lastName }}</small>
        </label>
        <label class="field">
          <span>Email</span>
          <input
            v-model="form.admin.email"
            class="input"
            :class="{ invalid: errors.email }"
            type="email"
            inputmode="email"
            autocomplete="email"
            required
          >
          <small class="field-hint">You sign in with this address.</small>
          <small
            v-if="errors.email"
            class="field-error"
          >{{ errors.email }}</small>
        </label>
        <label class="field">
          <span>Mobile number (optional)</span>
          <input
            v-model="form.admin.mobileNumber"
            class="input"
            :class="{ invalid: errors.mobileNumber }"
            type="tel"
            inputmode="tel"
            autocomplete="tel"
          >
          <small
            v-if="errors.mobileNumber"
            class="field-error"
          >{{ errors.mobileNumber }}</small>
        </label>
        <label class="field">
          <span>Password</span>
          <input
            v-model="form.admin.password"
            class="input"
            :class="{ invalid: errors.password }"
            type="password"
            autocomplete="new-password"
            required
          >
          <small class="field-hint">At least 10 characters.</small>
          <small
            v-if="errors.password"
            class="field-error"
          >{{ errors.password }}</small>
        </label>
        <label class="field">
          <span>Password again</span>
          <input
            v-model="form.admin.confirm"
            class="input"
            :class="{ invalid: errors.confirm }"
            type="password"
            autocomplete="new-password"
            required
          >
          <small
            v-if="errors.confirm"
            class="field-error"
          >{{ errors.confirm }}</small>
        </label>
      </template>

      <!-- 4. Email -->
      <template v-else-if="current === 'email'">
        <h2 class="setup-title">
          Send email from Yard Link
        </h2>
        <p class="field-hint mb-3">
          With email set up, new people get a welcome email and confirm their address, and anyone can choose to get work assignments and messages by email. You can change this later in Settings.
        </p>
        <div
          class="signup-roles"
          role="radiogroup"
          aria-label="Email"
        >
          <button
            type="button"
            class="signup-role"
            role="radio"
            :aria-checked="emailChoice === 'setup'"
            :aria-pressed="emailChoice === 'setup'"
            @click="emailChoice = 'setup'"
          >
            <b>Set up email</b>
          </button>
          <button
            type="button"
            class="signup-role"
            role="radio"
            :aria-checked="emailChoice === 'skip'"
            :aria-pressed="emailChoice === 'skip'"
            @click="emailChoice = 'skip'"
          >
            <b>Skip for now</b>
          </button>
        </div>

        <template v-if="emailChoice === 'setup'">
          <EmailSettingsFields
            v-model="email"
            :errors="errors"
            :company-name="form.company.name"
          />
          <div class="setup-test">
            <button
              class="btn-ghost setup-inline"
              type="button"
              :disabled="testing"
              @click="sendTest"
            >
              {{ testing ? 'Sending…' : 'Send a test email' }}
            </button>
            <small class="field-hint">Goes to {{ form.admin.email || 'your address' }}.</small>
          </div>
          <p
            v-if="testResult"
            class="banner"
            :class="testResult.ok ? 'ok' : 'err'"
            :role="testResult.ok ? 'status' : 'alert'"
          >
            <span aria-hidden="true">{{ testResult.ok ? '✓' : '✕' }}</span>
            <span>{{ testResult.message }}</span>
          </p>
        </template>
        <p
          v-else
          class="banner info"
        >
          <span aria-hidden="true">i</span>
          <span>Yard Link will not send any email. New accounts are approved by a dispatcher without confirming an address, and people are told about work and messages inside Yard Link only.</span>
        </p>
      </template>

      <!-- 5. Address for phones -->
      <template v-else-if="current === 'phones'">
        <label class="field">
          <span>Server address for phones</span>
          <input
            v-model="form.publicUrl"
            class="input mono"
            :class="{ invalid: errors.publicUrl }"
            inputmode="url"
            autocapitalize="off"
            spellcheck="false"
            placeholder="https://yard.yourcompany.com"
          >
          <small class="field-hint">
            The address the Yard Link iPhone app will use to reach this server. It is filled in with the address you are using right now. You can change it later in Settings.
          </small>
          <small
            v-if="errors.publicUrl"
            class="field-error"
          >{{ errors.publicUrl }}</small>
        </label>
        <p
          v-if="isLocalHttp"
          class="banner warn"
        >
          <span aria-hidden="true">!</span>
          <span>This is an http address. That works for trying Yard Link on your own network. Before drivers use it on the road, give the server an https address.</span>
        </p>
      </template>

      <!-- 6. Review -->
      <template v-else>
        <dl class="setup-review">
          <div>
            <dt>Database</dt>
            <dd>{{ databaseSummary }}</dd>
          </div>
          <div>
            <dt>Company</dt>
            <dd>{{ form.company.name }}</dd>
          </div>
          <div>
            <dt>Timezone</dt>
            <dd>{{ form.company.timezone.replace(/_/g, ' ') }}</dd>
          </div>
          <div>
            <dt>Dispatcher</dt>
            <dd>{{ form.admin.firstName }} {{ form.admin.lastName }} · {{ form.admin.email }}</dd>
          </div>
          <div>
            <dt>Email</dt>
            <dd>{{ emailSummary }}</dd>
          </div>
          <div>
            <dt>Phone address</dt>
            <dd>{{ form.publicUrl || 'The address you are on now' }}</dd>
          </div>
        </dl>
        <p
          v-if="!database?.external"
          class="banner warn"
        >
          <span aria-hidden="true">!</span>
          <span>You are using the built-in database. Your data can be deleted when Yard Link is updated or redeployed.</span>
        </p>
        <p class="field-hint">
          Finishing creates your account, signs you in, and shows the code drivers scan to connect.
        </p>
      </template>

      <div class="setup-actions">
        <button
          v-if="step > 0"
          class="btn-ghost"
          type="button"
          :disabled="submitting"
          @click="backward"
        >
          Back
        </button>
        <button
          class="btn-primary-action"
          type="submit"
          :disabled="submitting"
        >
          {{ continueLabel }}
        </button>
      </div>
    </form>
  </div>
</template>
