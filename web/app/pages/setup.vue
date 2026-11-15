<script setup lang="ts">
/**
 * First-run setup. Shown once, the first time someone opens a new Yard Link
 * server: name the company, create the first dispatcher, confirm the address
 * phones will use. After that everything is changed under Settings.
 */
definePageMeta({ layout: 'auth' })
useHead({ title: 'Set up Yard Link' })

const { fetch: refreshSession } = useUserSession()
const needsSetup = useState<boolean | null>('needs-setup', () => null)

const steps = ['Company', 'Your account', 'Phones', 'Finish'] as const
const step = ref(0)

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

onMounted(() => {
  if (!form.publicUrl) form.publicUrl = window.location.origin
})

const timezones = computed(() => {
  const common = ['America/New_York', 'America/Chicago', 'America/Denver', 'America/Phoenix', 'America/Los_Angeles', 'America/Anchorage', 'Pacific/Honolulu', 'America/Puerto_Rico']
  return common.includes(form.company.timezone) ? common : [form.company.timezone, ...common]
})

const errors = ref<Record<string, string>>({})
const submitting = ref(false)
const failure = ref('')

const isLocalHttp = computed(() => /^http:\/\//i.test(form.publicUrl.trim()))

function validate(index: number): boolean {
  const next: Record<string, string> = {}
  if (index === 0) {
    if (!form.company.name.trim()) next.companyName = 'Enter the company name.'
  }
  if (index === 1) {
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
  if (index === 2) {
    const value = form.publicUrl.trim()
    if (value && !/^https?:\/\/[^\s/]+/i.test(value)) next.publicUrl = 'Start with https:// — for example https://yard.yourcompany.com'
  }
  errors.value = next
  return Object.keys(next).length === 0
}

function forward() {
  if (!validate(step.value)) return
  step.value = Math.min(step.value + 1, steps.length - 1)
}

function backward() {
  errors.value = {}
  failure.value = ''
  step.value = Math.max(step.value - 1, 0)
}

async function finish() {
  if (submitting.value) return
  for (const index of [0, 1, 2]) {
    if (!validate(index)) {
      step.value = index
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
      },
    })
    needsSetup.value = false
    await refreshSession()
    await navigateTo(result.redirectTo, { replace: true })
  }
  catch (error) {
    failure.value = apiErrorMessage(error, 'Setup could not be saved. Check your entries and try again.')
  }
  finally {
    submitting.value = false
  }
}
</script>

<template>
  <div>
    <div class="auth-logo">
      <BrandLogo />
    </div>

    <AuthHeader
      title="Set up Yard Link"
      subtitle="A few questions and your server is ready"
    />

    <ol
      class="setup-steps"
      aria-label="Setup progress"
    >
      <li
        v-for="(label, index) in steps"
        :key="label"
        :class="{ on: index === step, done: index < step }"
        :aria-current="index === step ? 'step' : undefined"
      >
        {{ index + 1 }}. {{ label }}
      </li>
    </ol>

    <form
      class="card p-4"
      novalidate
      @submit.prevent="step === steps.length - 1 ? finish() : forward()"
    >
      <p
        v-if="failure"
        class="banner err"
        role="alert"
      >
        <span aria-hidden="true">✕</span>
        <span>{{ failure }}</span>
      </p>

      <!-- 1. Company -->
      <template v-if="step === 0">
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

      <!-- 2. First dispatcher -->
      <template v-else-if="step === 1">
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
          <small class="field-hint">You sign in with this. Yard Link does not send email.</small>
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

      <!-- 3. Address for phones -->
      <template v-else-if="step === 2">
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

      <!-- 4. Review -->
      <template v-else>
        <dl class="setup-review">
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
            <dt>Phone address</dt>
            <dd>{{ form.publicUrl || 'The address you are on now' }}</dd>
          </div>
        </dl>
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
          {{ step === steps.length - 1 ? (submitting ? 'Setting up…' : 'Finish setup') : 'Continue' }}
        </button>
      </div>
    </form>
  </div>
</template>
