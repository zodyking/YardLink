<script setup lang="ts">
import { formatPhoneInput } from '#shared/utils/phone'
import {
  SIGNUP_ROLE_LABELS,
  SIGNUP_ROLES,
  type SignupRole,
} from '#shared/utils/domain'

definePageMeta({ layout: 'auth' })
useHead({ title: 'Create an account' })

const form = reactive({
  role: 'DRIVER' as SignupRole,
  firstName: '',
  lastName: '',
  email: '',
  mobileNumber: '',
  password: '',
  inviteCode: '',
})

/** Masks to (000) 000-0000 as they type on the phone keypad. */
function onMobileInput(event: Event) {
  const input = event.target as HTMLInputElement
  const formatted = formatPhoneInput(input.value)
  form.mobileNumber = formatted
  // Keep the DOM in step when the mask rejects a character, otherwise Vue skips
  // the patch (model unchanged) and the stray keystroke stays on screen.
  if (input.value !== formatted) input.value = formatted
}

const submitting = ref(false)
const errorMessage = ref('')
const fieldErrors = ref<Record<string, string>>({})

/** Set once the account exists; the form is replaced by the confirmation. */
const submittedEmail = ref('')
/** True when a dispatcher has to approve the account before sign-in works. */
const approvalRequired = ref(true)
/** True when the employer has email set up: the address must be confirmed. */
const verificationRequired = ref(false)
/** False when the welcome email could not be sent. */
const emailSent = ref(true)
const resending = ref(false)
const resendMessage = ref('')

async function resend() {
  if (resending.value) return
  resending.value = true
  resendMessage.value = ''
  try {
    const result = await $fetch<{ message: string }>('/api/auth/resend-verification', {
      method: 'POST',
      body: { email: submittedEmail.value },
    })
    resendMessage.value = result.message
  }
  catch (error) {
    resendMessage.value = apiErrorMessage(error, 'Could not send the email. Try again in a minute.')
  }
  finally {
    resending.value = false
  }
}

async function submit() {
  if (submitting.value) return
  submitting.value = true
  errorMessage.value = ''
  fieldErrors.value = {}

  try {
    const result = await $fetch('/api/auth/signup', {
      method: 'POST',
      body: form,
    })
    submittedEmail.value = result.email
    approvalRequired.value = result.approvalRequired
    verificationRequired.value = result.verificationRequired
    emailSent.value = result.emailSent
  }
  catch (error) {
    const issues = (error as { data?: { data?: { issues?: Array<{ path: string, message: string }> } } })
      .data?.data?.issues

    if (issues?.length) {
      fieldErrors.value = Object.fromEntries(issues.map(i => [i.path, i.message]))
      errorMessage.value = 'Check the highlighted fields.'
    }
    else {
      errorMessage.value = apiErrorMessage(error, 'Could not create your account.')
    }
  }
  finally {
    submitting.value = false
  }
}

</script>

<template>
  <div v-if="submittedEmail">
    <div class="auth-logo">
      <BrandLogo />
    </div>
    <AuthHeader
      :title="verificationRequired ? 'Check your email' : approvalRequired ? 'Waiting for approval' : 'Account created'"
      :subtitle="verificationRequired || approvalRequired ? 'One more step' : 'You are ready'"
    />

    <div class="card p-4">
      <template v-if="verificationRequired">
        <p
          v-if="!emailSent"
          class="banner warn"
          role="alert"
        >
          <span aria-hidden="true">!</span>
          <span>Your account was created, but the welcome email could not be sent. Try sending it again below, or tell your dispatcher.</span>
        </p>
        <p class="text-[15px] leading-relaxed">
          Welcome, {{ form.firstName }}. We sent an email to <b class="break-all">{{ submittedEmail }}</b>.
          Open it and tap <b>Confirm My Email</b> to finish.
        </p>
        <p class="field-hint mt-3">
          {{ approvalRequired
            ? 'After you confirm, a dispatcher approves your account. You can sign in as soon as they do.'
            : 'After you confirm, you are signed in and ready to go.' }}
          The email can take a minute. Check your spam folder if you do not see it.
        </p>
        <button
          class="btn-ghost mt-4 w-full"
          type="button"
          :disabled="resending"
          @click="resend"
        >
          {{ resending ? 'Sending…' : 'Send the email again' }}
        </button>
        <p
          v-if="resendMessage"
          class="field-hint mt-2"
          role="status"
        >
          {{ resendMessage }}
        </p>
      </template>

      <template v-else>
        <p
          v-if="approvalRequired"
          class="text-[15px] leading-relaxed"
        >
          Your account for <b class="break-all">{{ submittedEmail }}</b> was created.
          A dispatcher has been notified and needs to approve it before you can sign in.
        </p>
        <p
          v-else
          class="text-[15px] leading-relaxed"
        >
          Your account for <b class="break-all">{{ submittedEmail }}</b> is ready. Sign in to get started.
        </p>

        <p
          v-if="approvalRequired"
          class="field-hint mt-3"
        >
          Let your dispatcher know you signed up. Once they approve you, sign in with the email and password you just chose.
        </p>
      </template>

      <NuxtLink
        to="/login"
        class="btn-primary-action mt-4"
      >
        Go to sign in
      </NuxtLink>
    </div>
  </div>

  <div v-else>
    <div class="auth-logo">
      <BrandLogo />
    </div>
    <AuthHeader
      title="Create your account"
      subtitle="Driver or dispatcher"
    />

    <form
      class="card p-4"
      novalidate
      @submit.prevent="submit"
    >
      <p
        v-if="errorMessage"
        class="banner err"
        role="alert"
      >
        <span aria-hidden="true">✕</span>
        <span>{{ errorMessage }}</span>
      </p>

      <div
        class="signup-roles"
        role="radiogroup"
        aria-label="Account type"
      >
        <button
          v-for="option in SIGNUP_ROLES"
          :key="option"
          type="button"
          class="signup-role"
          role="radio"
          :aria-checked="form.role === option"
          :aria-pressed="form.role === option"
          @click="form.role = option"
        >
          <b>{{ SIGNUP_ROLE_LABELS[option] }}</b>
        </button>
      </div>

      <div class="grid grid-cols-2 gap-3">
        <label class="field">
          <span>First name</span>
          <input
            v-model="form.firstName"
            class="input"
            :class="{ invalid: fieldErrors.firstName }"
            autocomplete="given-name"
            required
          >
          <small
            v-if="fieldErrors.firstName"
            class="field-error"
          >{{ fieldErrors.firstName }}</small>
        </label>

        <label class="field">
          <span>Last name</span>
          <input
            v-model="form.lastName"
            class="input"
            :class="{ invalid: fieldErrors.lastName }"
            autocomplete="family-name"
            required
          >
          <small
            v-if="fieldErrors.lastName"
            class="field-error"
          >{{ fieldErrors.lastName }}</small>
        </label>
      </div>

      <label class="field">
        <span>Mobile number</span>
        <input
          :value="form.mobileNumber"
          class="input"
          :class="{ invalid: fieldErrors.mobileNumber }"
          type="tel"
          inputmode="tel"
          autocomplete="tel"
          placeholder="(555) 123-4567"
          maxlength="14"
          required
          @input="onMobileInput"
        >
        <small
          v-if="fieldErrors.mobileNumber"
          class="field-error"
        >{{ fieldErrors.mobileNumber }}</small>
      </label>

      <label class="field">
        <span>Email</span>
        <input
          v-model="form.email"
          class="input"
          :class="{ invalid: fieldErrors.email }"
          type="email"
          inputmode="email"
          autocomplete="email"
          required
        >
        <small class="field-hint">You sign in with this address, and account emails go here.</small>
        <small
          v-if="fieldErrors.email"
          class="field-error"
        >{{ fieldErrors.email }}</small>
      </label>

      <label class="field">
        <span>Password</span>
        <input
          v-model="form.password"
          class="input"
          :class="{ invalid: fieldErrors.password }"
          type="password"
          autocomplete="new-password"
          required
        >
        <small class="field-hint">At least 10 characters.</small>
        <small
          v-if="fieldErrors.password"
          class="field-error"
        >{{ fieldErrors.password }}</small>
      </label>

      <label class="field">
        <span>Company join code</span>
        <input
          v-model="form.inviteCode"
          class="input mono"
          :class="{ invalid: fieldErrors.inviteCode }"
          autocomplete="one-time-code"
          required
        >
        <small class="field-hint">Your dispatcher has this code. It is shown next to the connection QR code in Yard Link.</small>
        <small
          v-if="fieldErrors.inviteCode"
          class="field-error"
        >{{ fieldErrors.inviteCode }}</small>
      </label>

      <button
        class="btn-primary-action"
        type="submit"
        :disabled="submitting"
      >
        {{ submitting ? 'Creating account…' : 'Create account' }}
      </button>
    </form>

    <p class="mt-6 text-center text-sm text-[var(--color-ink-500)]">
      Already registered?
      <NuxtLink
        to="/login"
        class="font-semibold text-[var(--color-blue-500)]"
      >
        Sign in
      </NuxtLink>
    </p>
  </div>
</template>
