/**
 * Session cookies are issued without `Secure` so a brand-new install reached
 * over plain http on the office network can still sign in. Whenever the
 * request did arrive over https — directly or through a reverse proxy — the
 * flag is added here, so nobody has to configure it.
 */
export default defineNitroPlugin((nitro) => {
  nitro.hooks.hook('beforeResponse', (event) => {
    if (getRequestProtocol(event, { xForwardedProto: true }) !== 'https') return
    const header = event.node.res.getHeader('set-cookie')
    if (!header) return
    const cookies = (Array.isArray(header) ? header : [String(header)])
      .map(cookie => (/;\s*secure/i.test(cookie) ? cookie : `${cookie}; Secure`))
    event.node.res.setHeader('set-cookie', cookies)
  })
})
