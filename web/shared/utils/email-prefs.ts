import type { Role } from './domain'

/**
 * What a person can ask to also receive by email.
 *
 * Everything always arrives inside Yard Link. Email is an extra copy, off
 * until the person turns it on in their own settings, and only available once
 * the employer has set up outgoing email.
 */
export const EMAIL_TOPICS = ['assignments', 'messages', 'signups'] as const
export type EmailTopic = (typeof EMAIL_TOPICS)[number]
export type EmailPrefs = Record<EmailTopic, boolean>

export const EMAIL_TOPIC_COPY: Record<EmailTopic, { label: string, hint: string, roles: readonly Role[] }> = {
  assignments: {
    label: 'Work assignments',
    hint: 'When dispatch assigns or changes your work for a day.',
    roles: ['DRIVER'],
  },
  messages: {
    label: 'New messages',
    hint: 'When someone writes to you and you have not read it yet.',
    roles: ['DRIVER', 'ADMIN'],
  },
  signups: {
    label: 'New accounts to approve',
    hint: 'When someone signs up and is waiting for a dispatcher.',
    roles: ['ADMIN'],
  },
}

export function emailTopicsForRole(role: Role | null | undefined): EmailTopic[] {
  if (!role) return []
  return EMAIL_TOPICS.filter(topic => EMAIL_TOPIC_COPY[topic].roles.includes(role))
}

/** Stored value → complete set, with anything missing or malformed off. */
export function parseEmailPrefs(raw: unknown): EmailPrefs {
  const row = raw && typeof raw === 'object' ? raw as Record<string, unknown> : {}
  return {
    assignments: row.assignments === true,
    messages: row.messages === true,
    signups: row.signups === true,
  }
}
