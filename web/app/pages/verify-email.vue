<script setup lang="ts">
/**
 * Where the Confirm My Email button in the welcome email lands. An account
 * that is already approved is signed in and sent to its home screen; one
 * still waiting for a dispatcher is told so.
 */
definePageMeta({ layout: 'auth' })
useHead({ title: 'Confirming your email' })

const route = useRoute()
const { fetch: refreshSession } = useUserSession()

const token = computed(() => (typeof route.query.token === 'string' ? route.query.token : ''))

type State = 'working' | 'waiting' | 'failed'
const state = ref<State>('working')
const errorMessage = ref('')

/** Asking for a new email, offered when the link no longer works. */
const email = ref('')
const resending = ref(false)
const resendMessage = ref('')

async function confirm() {
  if (!token.value) {
    state.value = 'failed'
    errorMessage.value = 'This link is missing its code. Ask for a new email below.'
    return
  }

  try {
    const result = await $fetch<{ approvalPending: boolean, redirectTo: string | null }>('/api/auth/verify-email', {
      method: 'POST',
      body: { token: token.value },
    })
    if (result.approvalPending || !result.redirectTo) {
      state.value = 'waiting'
      return
    }
    await refreshSession()
    await navigateTo(result.redirectTo, { replace: true })
  }
  catch (error) {
    state.value = 'failed'
    errorMessage.value = apiErrorMessage(error, 'This link is not valid any more.')
  }
}

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

const title = computed(() => {
  if (state.value === 'working') return 'Confirming your email'
  if (state.value === 'waiting') return 'Email confirmed'
  return 'This link did not work'
})

onMounted(confirm)
</script>

<template>
  <div>
    <div class="auth-logo">
      <BrandLogo />
    </div>
    <AuthHeader
      :title="title"
      :subtitle="state === 'waiting' ? 'One more step' : 'Email confirmation'"
    />

    <div class="card p-4">
      <p
        v-if="state === 'working'"
        class="text-[15px]"
        role="status"
      >
        Checking your link…
      </p>

      <template v-else-if="state === 'waiting'">
        <p
          class="banner ok"
          role="status"
        >
          <span aria-hidden="true">✓</span>
          <span>Your email address is confirmed.</span>
        </p>
        <p class="text-[15px] leading-relaxed">
          A dispatcher still needs to approve your account. You will get an email when they do, and then you can sign in.
        </p>
      </template>

      <template v-else>
        <p
          class="banner err"
          role="alert"
        >
          <span aria-hidden="true">✕</span>
          <span>{{ errorMessage }}</span>
        </p>

        <p class="field-hint">
          Links work once and for 24 hours. Enter your email address and we will send a new one.
        </p>

        <form
          class="mt-3"
          novalidate
          @submit.prevent="resend"
        >
          <label class="field">
            <span>Email</span>
            <input
              v-model="email"
              class="input"
              type="email"
              autocomplete="email"
              inputmode="email"
              required
            >
          </label>

          <button
            class="btn-primary-action mt-2"
            type="submit"
            :disabled="resending || !email"
          >
            {{ resending ? 'Sending…' : 'Send a new email' }}
          </button>
        </form>

        <p
          v-if="resendMessage"
          class="field-hint mt-2"
          role="status"
        >
          {{ resendMessage }}
        </p>
      </template>
    </div>

    <p class="mt-6 text-center text-sm text-[var(--color-ink-500)]">
      <NuxtLink
        to="/login"
        class="font-semibold text-[var(--color-blue-500)]"
      >
        Go to sign in
      </NuxtLink>
    </p>
  </div>
</template>
