import { describe, expect, it } from 'vitest'
import { formatSmtpFromHeader, parseSmtpFromHeader, smtpFromDomain } from '../shared/utils/smtp-from'

describe('parseSmtpFromHeader', () => {
  it('splits a quoted display name from the address', () => {
    expect(parseSmtpFromHeader('"Harbor Drayage" <no-reply@example.com>')).toEqual({
      fromName: 'Harbor Drayage',
      fromAddress: 'no-reply@example.com',
    })
  })

  it('splits an unquoted display name', () => {
    expect(parseSmtpFromHeader('Harbor Drayage <no-reply@example.com>')).toEqual({
      fromName: 'Harbor Drayage',
      fromAddress: 'no-reply@example.com',
    })
  })

  it('keeps punctuation inside the display name', () => {
    expect(parseSmtpFromHeader('"Harbor Drayage Company, LLC" <no-reply@example.com>')).toEqual({
      fromName: 'Harbor Drayage Company, LLC',
      fromAddress: 'no-reply@example.com',
    })
  })

  it('treats a bare address as the address', () => {
    expect(parseSmtpFromHeader('  no-reply@example.com ')).toEqual({
      fromName: '',
      fromAddress: 'no-reply@example.com',
    })
  })

  it('treats a bare word as a display name', () => {
    expect(parseSmtpFromHeader('Dispatch')).toEqual({ fromName: 'Dispatch', fromAddress: '' })
  })

  it('returns empty parts for empty input', () => {
    expect(parseSmtpFromHeader('')).toEqual({ fromName: '', fromAddress: '' })
  })
})

describe('formatSmtpFromHeader', () => {
  it('quotes the display name so punctuation cannot break the header', () => {
    expect(formatSmtpFromHeader('Harbor Drayage Company, LLC', 'no-reply@example.com'))
      .toBe('"Harbor Drayage Company, LLC" <no-reply@example.com>')
  })

  it('emits a bare address when there is no display name', () => {
    expect(formatSmtpFromHeader('', 'no-reply@example.com')).toBe('no-reply@example.com')
  })

  it('strips quotes and backslashes that would escape the header', () => {
    expect(formatSmtpFromHeader('Harbor "Drayage"', 'no-reply@example.com'))
      .toBe('"Harbor Drayage" <no-reply@example.com>')
  })

  it('is empty without an address, since a display name alone cannot send', () => {
    expect(formatSmtpFromHeader('Harbor Drayage', '')).toBe('')
  })

  it('round-trips through the parser', () => {
    const header = formatSmtpFromHeader('Harbor Drayage Company, LLC', 'no-reply@example.com')
    expect(parseSmtpFromHeader(header)).toEqual({
      fromName: 'Harbor Drayage Company, LLC',
      fromAddress: 'no-reply@example.com',
    })
  })
})

describe('smtpFromDomain', () => {
  it('reads the domain from a full header', () => {
    expect(smtpFromDomain('"Dispatch" <No-Reply@Example.COM>')).toBe('example.com')
  })

  it('reads the domain from a bare address', () => {
    expect(smtpFromDomain('no-reply@example.com')).toBe('example.com')
  })

  it('returns null when there is no address', () => {
    expect(smtpFromDomain('Dispatch')).toBeNull()
  })
})
