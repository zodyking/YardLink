import { eq } from 'drizzle-orm'
import { z } from 'zod'
import { emailTopicsForRole, parseEmailPrefs } from '#shared/utils/email-prefs'
import { users } from '../../database/schema'
import { loadAccountUser } from '../../utils/account'

const schema = z.object({
  assignments: z.boolean().optional(),
  messages: z.boolean().optional(),
  signups: z.boolean().optional(),
})

/**
 * Turns email copies on or off for the signed-in person, one topic at a time.
 * Topics that never reach this person's role are ignored.
 */
export default defineEventHandler(async (event) => {
  const auth = await requireAuth(event)
  const body = await readValidatedJson(event, schema)
  const user = await loadAccountUser(auth.userId)

  const prefs = parseEmailPrefs(user.emailPrefs)
  for (const topic of emailTopicsForRole(auth.role)) {
    const value = body[topic]
    if (value !== undefined) prefs[topic] = value
  }

  await useDb()
    .update(users)
    .set({ emailPrefs: prefs, updatedAt: new Date() })
    .where(eq(users.id, auth.userId))

  return { ok: true, prefs }
})
