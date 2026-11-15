import { sql } from 'drizzle-orm'
import { companyMemberships, users } from '../database/schema'
import type { DispatchTaskView } from './tasks'
import { postSystemNotice } from './messages'
import { DISPATCH_TASK_KIND_LABELS } from '#shared/utils/domain'
import { displayContainerNumber } from '#shared/utils/dispatch-cards'

function formatWorkDate(isoDate: string): string {
  const [year, month, day] = isoDate.split('-').map(Number)
  if (!year || !month || !day) return isoDate
  return new Intl.DateTimeFormat('en-US', {
    weekday: 'short',
    month: 'short',
    day: 'numeric',
    timeZone: 'UTC',
  }).format(new Date(Date.UTC(year, month - 1, day)))
}

function taskLines(tasks: DispatchTaskView[]): string[] {
  return tasks.map((task, index) => {
    const box = displayContainerNumber(task.card.containerNumber)
    const place = task.card.locationName || task.card.destinationLocationName
    return [`${index + 1}. ${DISPATCH_TASK_KIND_LABELS[task.kind]}`, box, place].filter(Boolean).join(' · ')
  })
}

/**
 * Tell a driver their day's work was assigned or changed. This used to be an
 * email; it is now a message in their dispatch conversation, where they can
 * answer it. Never throws — the tasks are already saved.
 */
export async function notifyDriverTaskChange(input: {
  email: string
  firstName: string
  workDate: string
  dispatcherName: string
  kind: 'assigned' | 'updated'
  tasks: DispatchTaskView[]
}): Promise<void> {
  try {
    const db = useDb()
    const [driver] = await db
      .select({ userId: users.id, companyId: companyMemberships.companyId })
      .from(users)
      .innerJoin(companyMemberships, sql`${companyMemberships.userId} = ${users.id}`)
      .where(sql`lower(${users.email}) = lower(${input.email})`)
      .limit(1)
    if (!driver) return

    const verb = input.kind === 'assigned' ? 'assigned your work' : 'updated your work'
    const body = [
      `${input.dispatcherName} ${verb} for ${formatWorkDate(input.workDate)}.`,
      '',
      ...taskLines(input.tasks),
      '',
      'Open Tasks to start.',
    ].join('\n')

    await postSystemNotice(db, {
      companyId: driver.companyId,
      driverUserId: driver.userId,
      kind: 'TASKS',
      body,
      senderName: input.dispatcherName,
    })
  }
  catch (error) {
    console.warn('[tasks] could not post the assignment notice', error)
  }
}
