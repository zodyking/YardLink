/**
 * Unread message count for the navigation badge. One timer for the whole
 * app, paused while the tab is hidden so an idle phone is not polling.
 */
const POLL_MS = 30_000
let timer: ReturnType<typeof setInterval> | null = null

export function useUnreadMessages() {
  const unread = useState('unread-messages', () => 0)
  const { loggedIn } = useUserSession()

  async function refresh() {
    if (!loggedIn.value) {
      unread.value = 0
      return
    }
    try {
      unread.value = (await $fetch<{ unread: number }>('/api/messages/unread')).unread
    }
    catch {
      // Keep the last known count; the next tick tries again.
    }
  }

  if (import.meta.client && !timer) {
    void refresh()
    timer = setInterval(() => {
      if (document.visibilityState === 'visible') void refresh()
    }, POLL_MS)
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'visible') void refresh()
    })
  }

  return { unread, refresh }
}
