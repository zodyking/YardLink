import { describe, expect, it } from 'vitest'
import { emailTopicsForRole, parseEmailPrefs } from '../shared/utils/email-prefs'

describe('email preferences', () => {
  it('is off for everything until the person turns a topic on', () => {
    expect(parseEmailPrefs({})).toEqual({ assignments: false, messages: false, signups: false })
    expect(parseEmailPrefs(null)).toEqual({ assignments: false, messages: false, signups: false })
  })

  it('keeps only real true values', () => {
    expect(parseEmailPrefs({ assignments: true, messages: 'yes', signups: 1, other: true }))
      .toEqual({ assignments: true, messages: false, signups: false })
  })

  it('offers each role only the topics that reach it', () => {
    expect(emailTopicsForRole('DRIVER')).toEqual(['assignments', 'messages'])
    expect(emailTopicsForRole('ADMIN')).toEqual(['messages', 'signups'])
    expect(emailTopicsForRole(null)).toEqual([])
  })
})
