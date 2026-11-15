<script setup lang="ts">
import { ACCOUNT_LOCKED_MESSAGE } from '#shared/utils/account-lock'

definePageMeta({ layout: 'auth' })
useHead({ title: 'Sign in' })

const route = useRoute()
const { fetch: refreshSession } = useUserSession()

const email = ref('')
const password = ref('')
const submitting = ref(false)
const errorMessage = ref('')
const accountLocked = ref(false)

/** The password was correct but a dispatcher has not approved the account yet. */
const awaitingApproval = ref(false)
/** The password was correct but the address has not been confirmed yet. */
const needsConfirmation = ref(false)
const resending = ref(false)
const resendMessage = ref('')
/** Arrived from setup after reconnecting a database that already had a company. */
const restored = route.query.restored === '1'

async function resend() {
  if (resending.value) return
  resending.value = true
  resendMessage.value = ''
  try {
    const result = await $fetch<{ message: string }>('/api/auth/resend-verification', {
      method: 'POST',
      body: { email: email.value },
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

if (route.query.locked === '1') {
  accountLocked.value = true
  errorMessage.value = ACCOUNT_LOCKED_MESSAGE
}

function lockedFromError(error: unknown) {
  const detail = (error as { data?: { data?: { accountLocked?: boolean }, accountLocked?: boolean } }).data
  return Boolean(detail?.data?.accountLocked || detail?.accountLocked)
}

async function submit() {
  if (submitting.value) return
  submitting.value = true
  errorMessage.value = ''
  awaitingApproval.value = false
  needsConfirmation.value = false
  resendMessage.value = ''
  accountLocked.value = false

  try {
    const result = await $fetch('/api/auth/login', {
      method: 'POST',
      body: { email: email.value, password: password.value },
    })

    await refreshSession()

    // Dispatchers go to the map board; drivers may resume a deep link.
    const redirect = typeof route.query.redirect === 'string' && result.role !== 'ADMIN'
      ? route.query.redirect
      : result.redirectTo

    const { withLoader } = useBrandLoader()
    await withLoader(() => navigateTo(redirect), { caption: 'Welcome' })
  }
  catch (error) {
    const detail = (error as { data?: { data?: { approvalPending?: boolean, emailUnverified?: boolean } } })
      .data?.data
    awaitingApproval.value = Boolean(detail?.approvalPending)
    needsConfirmation.value = Boolean(detail?.emailUnverified)
    accountLocked.value = lockedFromError(error)
    errorMessage.value = accountLocked.value
      ? ACCOUNT_LOCKED_MESSAGE
      : apiErrorMessage(error, 'Email or password is incorrect.')
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
      title="Sign in"
      subtitle="Drivers and dispatchers"
    />

    <form
      class="card p-4"
      novalidate
      @submit.prevent="submit"
    >
      <p
        v-if="restored && !errorMessage"
        class="banner ok"
        role="status"
      >
        <span aria-hidden="true">✓</span>
        <span>Your database is connected and your records are in place. Sign in with your existing account.</span>
      </p>

      <p
        v-if="errorMessage"
        class="banner"
        :class="accountLocked ? 'warn' : 'err'"
        role="alert"
      >
        <span aria-hidden="true">{{ accountLocked ? '!' : '✕' }}</span>
        <span>{{ errorMessage }}</span>
      </p>

      <label class="field">
        <span>Email</span>
        <input
          v-model="email"
          class="input"
          type="email"
          autocomplete="email"
          inputmode="email"
          required
          :aria-invalid="Boolean(errorMessage)"
        >
      </label>

      <label class="field">
        <span>Password</span>
        <input
          v-model="password"
          class="input"
          type="password"
          autocomplete="current-password"
          required
        >
      </label>

      <button
        class="btn-primary-action mt-2"
        type="submit"
        :disabled="submitting"
      >
        {{ submitting ? 'Signing in…' : 'Sign in' }}
      </button>

      <p
        v-if="awaitingApproval"
        class="field-hint mt-2"
        role="status"
      >
        Dispatchers approve new accounts under Drivers in Yard Link.
      </p>

      <template v-if="needsConfirmation">
        <button
          class="btn-ghost mt-3 w-full"
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
    </form>

    <p class="mt-6 text-center text-sm text-[var(--color-ink-500)]">
      New here?
      <NuxtLink
        to="/signup"
        class="font-semibold text-[var(--color-blue-500)]"
      >
        Create an account
      </NuxtLink>
    </p>
  </div>
</template>
