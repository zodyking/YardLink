/**
 * Route guard.
 *
 * This is a usability layer only — every API route independently enforces role
 * and tenant rules server-side (spec 21).
 *
 * Dispatchers (ADMIN) land on the map board. `/` stays the driver operational
 * home, so signed-in admins are redirected away from it.
 */
import { roleHomePath } from '#shared/utils/domain'

const PUBLIC_ROUTES = new Set(['/login', '/signup', '/setup'])

export default defineNuxtRouteMiddleware(async (to) => {
  const { loggedIn, user } = useUserSession()

  // A fresh install has nobody to sign in as: every signed-out visit goes to
  // the setup wizard until the first dispatcher account exists. Asked once
  // per page load, and never again after setup is done.
  if (!loggedIn.value) {
    const needsSetup = useState<boolean | null>('needs-setup', () => null)
    if (needsSetup.value !== false) {
      try {
        needsSetup.value = (await $fetch<{ needsSetup: boolean }>('/api/setup/status')).needsSetup
      }
      catch {
        needsSetup.value = null
      }
    }
    if (needsSetup.value && to.path !== '/setup') return navigateTo('/setup')
    if (needsSetup.value === false && to.path === '/setup') return navigateTo('/login')
  }

  if (PUBLIC_ROUTES.has(to.path)) {
    if (loggedIn.value) {
      return navigateTo(roleHomePath(user.value?.role))
    }
    return
  }

  if (!loggedIn.value) {
    return navigateTo({ path: '/login', query: to.fullPath === '/' ? undefined : { redirect: to.fullPath } })
  }

  // Messages belong to everyone; each role keeps its own shell around them.
  if (to.path === '/messages' || to.path.startsWith('/messages/')) return

  const isAdminRoute = to.path.startsWith('/admin')
  const locationPool = to.path === '/locations' || to.path.startsWith('/locations/')
  const containerRecord = to.path.startsWith('/containers')
  const moreArea = to.path === '/more' || to.path.startsWith('/reset')

  if (isAdminRoute && user.value?.role !== 'ADMIN') {
    return navigateTo('/')
  }

  // Location records are a shared company asset — admins create them, drivers
  // pick them. Pickup/scan remain driver-only. The More cheat-code box and
  // hidden operator page (clear records) stay reachable
  // for admins.
  if (!isAdminRoute && user.value?.role === 'ADMIN' && !locationPool && !containerRecord && !moreArea) {
    return navigateTo(roleHomePath('ADMIN'))
  }
})
