import { listContacts } from '../../services/messages'
import { requireAuth } from '../../utils/session'

export default defineEventHandler(async (event) => {
  const auth = await requireAuth(event)
  return { contacts: await listContacts(useDb(), auth) }
})
