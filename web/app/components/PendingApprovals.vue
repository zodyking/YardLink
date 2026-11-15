<script setup lang="ts">
/**
 * People who signed up with the join code and are waiting to be let in.
 * A dispatcher vouches for each person. With email set up, the person also
 * confirms their own address, and the row says whether they have yet.
 */
interface Pending {
  userId: string
  firstName: string
  lastName: string
  email: string
  emailVerifiedAt: string | null
  mobileNumber: string | null
  role: 'DRIVER' | 'ADMIN'
  requestedAt: string
}

const emit = defineEmits<{ changed: [] }>()
const { data, refresh } = await useFetch<{ pending: Pending[] }>('/api/admin/people')
const pending = computed(() => data.value?.pending ?? [])
const busy = ref<string | null>(null)
const error = ref('')
const declining = ref<Pending | null>(null)

async function review(person: Pending, approve: boolean) {
  if (busy.value) return
  busy.value = person.userId
  error.value = ''
  try {
    await $fetch(`/api/admin/people/${person.userId}/approval`, { method: 'POST', body: { approve } })
    declining.value = null
    await refresh()
    emit('changed')
  }
  catch (err) {
    error.value = apiErrorMessage(err, 'Could not save that. Try again.')
  }
  finally {
    busy.value = null
  }
}

function asked(value: string) {
  return new Date(value).toLocaleString(undefined, { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' })
}
</script>

<template>
  <section
    v-if="pending.length"
    class="approvals card"
    aria-label="Waiting for approval"
  >
    <header>
      <b>Waiting for approval</b>
      <span class="approvals-count">{{ pending.length }}</span>
    </header>
    <p
      v-if="error"
      class="banner err"
      role="alert"
    >
      <span aria-hidden="true">✕</span>
      <span>{{ error }}</span>
    </p>
    <div
      v-for="person in pending"
      :key="person.userId"
      class="approvals-row"
    >
      <div>
        <b>{{ person.firstName }} {{ person.lastName }}</b>
        <small>{{ person.role === 'ADMIN' ? 'Dispatcher' : 'Driver' }} · {{ person.email }} · signed up {{ asked(person.requestedAt) }}{{ person.emailVerifiedAt ? '' : ' · email not confirmed yet' }}</small>
      </div>
      <div class="approvals-actions">
        <button
          class="btn-ghost"
          type="button"
          :disabled="busy === person.userId"
          @click="declining = person"
        >
          Decline
        </button>
        <button
          class="btn-primary-action"
          type="button"
          :disabled="busy === person.userId"
          @click="review(person, true)"
        >
          {{ busy === person.userId ? 'Saving…' : 'Approve' }}
        </button>
      </div>
    </div>

    <BottomSheet
      :open="Boolean(declining)"
      title="Decline this sign-up?"
      @close="declining = null"
    >
      <p class="px-4 pb-2 text-sm">
        {{ declining?.firstName }} {{ declining?.lastName }}'s sign-up will be removed. They can sign up again with the join code.
      </p>
      <div class="sheet-actions">
        <button
          type="button"
          class="btn-cancel"
          @click="declining = null"
        >
          Keep waiting
        </button>
        <button
          type="button"
          class="btn-save"
          :disabled="Boolean(busy)"
          @click="declining && review(declining, false)"
        >
          Decline sign-up
        </button>
      </div>
    </BottomSheet>
  </section>
</template>
