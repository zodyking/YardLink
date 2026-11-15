<script setup lang="ts">
/**
 * Messages — drivers and dispatch talk here instead of by text.
 * A list of conversations beside (or, on a phone, in front of) the open one.
 */
import { documentFileSrc, isImageDocument } from '~/utils/documents'

useHead({ title: 'Messages' })

const { user } = useUserSession()
setPageLayout(user.value?.role === 'ADMIN' ? 'admin' : 'default')
const isDriver = computed(() => user.value?.role === 'DRIVER')

interface ThreadRow {
  id: string
  kind: 'DISPATCH' | 'DIRECT'
  title: string
  subtitle: string
  lastMessageAt: string | null
  lastMessagePreview: string | null
  unread: number
}
interface MessageFile { id: string, fileName: string, mimeType: string | null, category: string }
interface MessageRow {
  id: string
  senderUserId: string | null
  senderName: string
  mine: boolean
  body: string
  kind: string
  tripId: string | null
  documents: MessageFile[]
  createdAt: string
}

const route = useRoute()
const router = useRouter()
const { refresh: refreshUnread } = useUnreadMessages()

const { data: inbox, refresh: refreshInbox, pending: inboxPending } = await useFetch<{ threads: ThreadRow[] }>('/api/messages')
const threads = computed(() => inbox.value?.threads ?? [])

const openId = computed(() => (typeof route.query.t === 'string' ? route.query.t : ''))
const openThread = computed(() => threads.value.find(thread => thread.id === openId.value) ?? null)

const messages = ref<MessageRow[]>([])
const loadingThread = ref(false)
const threadError = ref('')
const draft = ref('')
const sending = ref(false)
const sendError = ref('')
const scroller = ref<HTMLElement | null>(null)

const picking = ref(false)
const contacts = ref<Array<{ userId: string, name: string, role: string }>>([])
const contactQuery = ref('')
const filteredContacts = computed(() => {
  const needle = contactQuery.value.trim().toLowerCase()
  return needle ? contacts.value.filter(person => person.name.toLowerCase().includes(needle)) : contacts.value
})

const taskFlash = ref<Record<string, string>>({})

function scrollToEnd() {
  nextTick(() => {
    if (scroller.value) scroller.value.scrollTop = scroller.value.scrollHeight
  })
}

async function loadThread(id: string) {
  loadingThread.value = true
  threadError.value = ''
  messages.value = []
  try {
    const result = await $fetch<{ messages: MessageRow[] }>(`/api/messages/threads/${id}`)
    if (openId.value !== id) return
    messages.value = result.messages
    scrollToEnd()
    await Promise.all([refreshInbox(), refreshUnread()])
  }
  catch (error) {
    threadError.value = apiErrorMessage(error, 'Could not open that conversation.')
  }
  finally {
    loadingThread.value = false
  }
}

/** Pick up anything new in the open conversation and the list. */
async function poll() {
  if (document.visibilityState !== 'visible') return
  const id = openId.value
  try {
    if (id && !loadingThread.value) {
      const last = messages.value.at(-1)
      const result = await $fetch<{ messages: MessageRow[] }>(`/api/messages/threads/${id}`, {
        query: last ? { after: new Date(last.createdAt).toISOString() } : undefined,
      })
      if (openId.value === id && result.messages.length) {
        const known = new Set(messages.value.map(message => message.id))
        const fresh = result.messages.filter(message => !known.has(message.id))
        if (fresh.length) {
          messages.value = [...messages.value, ...fresh]
          scrollToEnd()
        }
      }
    }
    await refreshInbox()
  }
  catch {
    // Weak signal: the next tick tries again.
  }
}

let timer: ReturnType<typeof setInterval> | null = null
onMounted(() => {
  timer = setInterval(poll, 6_000)
})
onBeforeUnmount(() => {
  if (timer) clearInterval(timer)
})

watch(openId, (id) => {
  draft.value = ''
  sendError.value = ''
  if (id) void loadThread(id)
  else messages.value = []
}, { immediate: true })

function open(id: string) {
  router.push({ path: '/messages', query: { t: id } })
}

function back() {
  router.push({ path: '/messages' })
}

async function send() {
  const body = draft.value.trim()
  if (!body || sending.value || !openId.value) return
  sending.value = true
  sendError.value = ''
  // The id is made here so a retry on a weak signal cannot send twice.
  const id = crypto.randomUUID()
  try {
    const result = await $fetch<{ message: MessageRow }>(`/api/messages/threads/${openId.value}`, {
      method: 'POST',
      body: { id, body },
    })
    messages.value = [...messages.value, { ...result.message, mine: true, documents: [] }]
    draft.value = ''
    scrollToEnd()
    void refreshInbox()
  }
  catch (error) {
    sendError.value = apiErrorMessage(error, 'Not sent. Check your signal and try again.')
  }
  finally {
    sending.value = false
  }
}

async function startPicking() {
  picking.value = true
  contactQuery.value = ''
  try {
    contacts.value = (await $fetch<{ contacts: typeof contacts.value }>('/api/messages/contacts')).contacts
  }
  catch {
    contacts.value = []
  }
}

async function startWith(userId: string) {
  try {
    const result = await $fetch<{ threadId: string }>('/api/messages/threads', {
      method: 'POST',
      body: { userId },
    })
    picking.value = false
    await refreshInbox()
    open(result.threadId)
  }
  catch (error) {
    threadError.value = apiErrorMessage(error, 'Could not start that conversation.')
  }
}

/** Driver: turn a dispatch message into a task, like pasting a text used to. */
async function saveAsTask(message: MessageRow) {
  try {
    await $fetch('/api/tasks', { method: 'POST', body: { text: message.body } })
    taskFlash.value = { ...taskFlash.value, [message.id]: 'Added to Tasks' }
  }
  catch (error) {
    taskFlash.value = { ...taskFlash.value, [message.id]: apiErrorMessage(error, 'Could not add it.') }
  }
}

function stamp(value: string | null) {
  if (!value) return ''
  const date = new Date(value)
  const sameDay = date.toDateString() === new Date().toDateString()
  return sameDay
    ? date.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' })
    : date.toLocaleDateString(undefined, { month: 'short', day: 'numeric' })
}

function fullStamp(value: string) {
  return new Date(value).toLocaleString(undefined, { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' })
}

function kindLabel(kind: string) {
  if (kind === 'TRIP_UPDATE') return 'Trip update'
  if (kind === 'TASKS') return 'Work assigned'
  if (kind === 'ACCOUNT') return 'Account'
  return ''
}
</script>

<template>
  <section
    class="msg-page"
    :class="{ 'has-open': Boolean(openId) }"
  >
    <aside
      class="msg-list"
      aria-label="Conversations"
    >
      <div class="msg-list-head">
        <div>
          <span class="eyebrow">Yard Link</span>
          <h1 class="d-title">
            Messages
          </h1>
        </div>
        <button
          class="btn-ghost msg-new"
          type="button"
          @click="startPicking"
        >
          New
        </button>
      </div>

      <p
        v-if="inboxPending && !threads.length"
        class="msg-empty"
      >
        Loading conversations…
      </p>
      <p
        v-else-if="!threads.length"
        class="msg-empty"
      >
        {{ isDriver ? 'No messages yet. Tap New to write to dispatch.' : 'No messages yet. Tap New to write to a driver.' }}
      </p>

      <button
        v-for="thread in threads"
        :key="thread.id"
        class="msg-row"
        :class="{ on: thread.id === openId, unread: thread.unread > 0 }"
        type="button"
        @click="open(thread.id)"
      >
        <span
          class="msg-avatar"
          aria-hidden="true"
        >{{ thread.title.slice(0, 1).toUpperCase() }}</span>
        <span class="msg-row-main">
          <span class="msg-row-top">
            <b>{{ thread.title }}</b>
            <time>{{ stamp(thread.lastMessageAt) }}</time>
          </span>
          <span class="msg-row-preview">{{ thread.lastMessagePreview || thread.subtitle }}</span>
        </span>
        <span
          v-if="thread.unread"
          class="msg-count"
          :aria-label="`${thread.unread} unread`"
        >{{ thread.unread > 9 ? '9+' : thread.unread }}</span>
      </button>
    </aside>

    <div class="msg-thread">
      <template v-if="openId">
        <header class="msg-thread-head">
          <button
            class="msg-back"
            type="button"
            aria-label="Back to conversations"
            @click="back"
          >
            ‹
          </button>
          <div>
            <b>{{ openThread?.title ?? 'Conversation' }}</b>
            <small>{{ openThread?.subtitle }}</small>
          </div>
        </header>

        <div
          ref="scroller"
          class="msg-scroll"
          aria-live="polite"
        >
          <p
            v-if="threadError"
            class="banner err"
            role="alert"
          >
            <span aria-hidden="true">✕</span>
            <span>{{ threadError }}</span>
          </p>
          <p
            v-else-if="loadingThread"
            class="msg-empty"
          >
            Loading…
          </p>
          <p
            v-else-if="!messages.length"
            class="msg-empty"
          >
            Nothing here yet. Say hello.
          </p>

          <article
            v-for="message in messages"
            :key="message.id"
            class="msg-bubble"
            :class="{ mine: message.mine, system: !message.senderUserId }"
          >
            <header>
              <b>{{ message.mine ? 'You' : message.senderName }}</b>
              <span
                v-if="kindLabel(message.kind)"
                class="msg-kind"
              >{{ kindLabel(message.kind) }}</span>
              <time>{{ fullStamp(message.createdAt) }}</time>
            </header>
            <p
              v-if="message.body"
              class="msg-body"
            >
              {{ message.body }}
            </p>
            <div
              v-if="message.documents.length"
              class="msg-files"
            >
              <a
                v-for="file in message.documents"
                :key="file.id"
                :href="documentFileSrc(file.id)"
                target="_blank"
                rel="noopener"
                class="msg-file"
              >
                <img
                  v-if="isImageDocument(file)"
                  :src="documentFileSrc(file.id, true)"
                  :alt="file.fileName"
                  loading="lazy"
                >
                <span v-else>{{ file.fileName }}</span>
              </a>
            </div>
            <footer v-if="message.tripId || (isDriver && !message.mine && message.kind === 'TEXT')">
              <NuxtLink
                v-if="message.tripId"
                :to="`/trips/${message.tripId}`"
              >
                Open trip
              </NuxtLink>
              <button
                v-if="isDriver && !message.mine && message.kind === 'TEXT' && !taskFlash[message.id]"
                type="button"
                @click="saveAsTask(message)"
              >
                Add to Tasks
              </button>
              <span v-if="taskFlash[message.id]">{{ taskFlash[message.id] }}</span>
            </footer>
          </article>
        </div>

        <form
          class="msg-compose"
          @submit.prevent="send"
        >
          <p
            v-if="sendError"
            class="field-error"
            role="alert"
          >
            {{ sendError }}
          </p>
          <div class="msg-compose-row">
            <textarea
              v-model="draft"
              class="input"
              rows="1"
              maxlength="4000"
              placeholder="Write a message"
              aria-label="Message"
              @keydown.enter.exact.prevent="send"
            />
            <button
              class="btn-primary-action"
              type="submit"
              :disabled="sending || !draft.trim()"
            >
              {{ sending ? 'Sending…' : 'Send' }}
            </button>
          </div>
        </form>
      </template>

      <div
        v-else
        class="msg-placeholder"
      >
        <img
          src="/brand/symbol.svg"
          alt=""
          width="96"
        >
        <p>Choose a conversation, or start a new one.</p>
      </div>
    </div>

    <BottomSheet
      :open="picking"
      title="New message"
      @close="picking = false"
    >
      <div class="p-4">
        <input
          v-model="contactQuery"
          class="input"
          type="search"
          placeholder="Search people"
          aria-label="Search people"
        >
      </div>
      <button
        v-for="person in filteredContacts"
        :key="person.userId"
        class="menu-row"
        type="button"
        @click="startWith(person.userId)"
      >
        {{ person.name }}
        <small class="msg-role">{{ person.role === 'ADMIN' ? 'Dispatcher' : 'Driver' }}</small>
      </button>
      <p
        v-if="!filteredContacts.length"
        class="msg-empty"
      >
        Nobody matches that search.
      </p>
    </BottomSheet>
  </section>
</template>
