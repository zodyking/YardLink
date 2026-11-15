import { describe, expect, it } from 'vitest'
import { checkEmailSettings, emptyEmailSettings } from '../shared/utils/email-settings'

describe('outgoing email form', () => {
  it('accepts a mailbox that sends as itself', () => {
    const form = { ...emptyEmailSettings(), host: 'smtp.example.com', user: 'dispatch@example.com', password: 'x' }
    expect(checkEmailSettings(form)).toEqual({})
  })

  it('needs a server, a real port and somewhere to send from', () => {
    const errors = checkEmailSettings({ ...emptyEmailSettings(), port: '70000', user: 'apikey' })
    expect(Object.keys(errors).sort()).toEqual(['fromEmail', 'host', 'port'])
  })

  it('rejects a pasted address in place of the server name', () => {
    expect(checkEmailSettings({ ...emptyEmailSettings(), host: 'https://smtp.example.com', user: 'a@b.co' }))
      .toHaveProperty('host')
  })

  it('accepts a login that is not a mailbox when a sender address is given', () => {
    const form = { ...emptyEmailSettings(), host: 'smtp.example.com', user: 'apikey', fromEmail: 'yard@example.com' }
    expect(checkEmailSettings(form)).toEqual({})
  })
})
