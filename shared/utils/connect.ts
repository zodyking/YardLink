/**
 * Employer connection code.
 *
 * The QR code an employer shows to staff holds only where the server is and
 * what to call it — never a password, a session, or the join code. Signing in
 * still happens afterwards, against that server.
 *
 *   yardlink://connect?server=https%3A%2F%2Fyard.example.com&name=Acme%20Drayage
 */
export const CONNECT_SCHEME = 'yardlink'
export const CONNECT_API_VERSION = 1

export interface ConnectTarget {
  server: string
  name: string
}

export function buildConnectLink(target: ConnectTarget): string {
  const params = new URLSearchParams({ server: target.server, name: target.name })
  return `${CONNECT_SCHEME}://connect?${params.toString()}`
}

/** Accepts the connection link, or a bare server address typed by hand. */
export function parseConnectLink(raw: string): ConnectTarget | null {
  const text = raw.trim()
  if (!text) return null

  let server = ''
  let name = ''
  if (text.toLowerCase().startsWith(`${CONNECT_SCHEME}://`)) {
    const query = text.slice(text.indexOf('?') + 1)
    if (!text.includes('?')) return null
    const params = new URLSearchParams(query)
    server = params.get('server') ?? ''
    name = params.get('name') ?? ''
  }
  else {
    server = /^https?:\/\//i.test(text) ? text : `https://${text}`
  }

  try {
    const url = new URL(server)
    if (url.protocol !== 'https:' && url.protocol !== 'http:') return null
    if (!url.hostname) return null
    return { server: `${url.protocol}//${url.host}`, name: name.trim() }
  }
  catch {
    return null
  }
}
