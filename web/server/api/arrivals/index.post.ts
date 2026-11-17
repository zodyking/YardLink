import { z } from 'zod'
import { openArrival, settleDueArrivals } from '../../services/arrivals'
import { requireDriver } from '../../utils/session'

const schema = z.object({
  latitude: z.number().min(-90).max(90),
  longitude: z.number().min(-180).max(180),
  accuracyMeters: z.number().nullish(),
  /** When the phone crossed in — it may have been offline since. */
  at: z.string().datetime().optional(),
})

/** The phone crossed into a site's circle while a trip was live. */
export default defineEventHandler(async (event) => {
  const auth = await requireDriver(event)
  const body = await readValidatedJson(event, schema)
  const db = useDb()

  const at = body.at ? new Date(body.at) : new Date()
  const opened = await openArrival(db, auth, {
    latitude: body.latitude,
    longitude: body.longitude,
    accuracyMeters: body.accuracyMeters ?? null,
    at: Number.isNaN(at.getTime()) ? new Date() : at,
  })

  // A phone that has been out of signal may be carrying a late crossing.
  await settleDueArrivals(db)

  if (!opened) return { asked: false as const }
  return {
    asked: true as const,
    arrival: {
      id: opened.arrival.id,
      locationName: opened.locationName,
      enteredAt: opened.arrival.enteredAt.toISOString(),
      autoAt: opened.arrival.autoAt.toISOString(),
    },
  }
})
