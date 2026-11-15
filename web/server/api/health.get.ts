import { sql } from 'drizzle-orm'
import { useOcrService } from '../services/ocr'
import { useObjectStorage } from '../services/storage'

/**
 * Container health probe, also used by the Dockerfile HEALTHCHECK.
 *
 * Docker probes this every 30s — keep it to the database.
 * OCR and object storage are `?full=1` so a slow sidecar cannot time out the probe.
 */
export default defineEventHandler(async (event) => {
  const checks: Record<string, { status: 'ok' | 'degraded' | 'error', detail?: string }> = {}

  try {
    await useDb().execute(sql`select 1`)
    checks.database = { status: 'ok' }
  }
  catch (error) {
    checks.database = { status: 'error', detail: error instanceof Error ? error.message : 'unreachable' }
  }

  const full = getQuery(event).full === '1' || getQuery(event).full === 'true'
  if (full) {
    const ocr = await useOcrService().healthCheck()
    checks.ocr = { status: ocr.healthy ? 'ok' : 'degraded', detail: ocr.message }

    const storage = await useObjectStorage().healthCheck()
    checks.storage = { status: storage.healthy ? 'ok' : 'degraded', detail: storage.message }
  }

  const healthy = checks.database?.status === 'ok'
  if (!healthy) setResponseStatus(event, 503)

  return {
    status: healthy ? 'ok' : 'error',
    uptimeSeconds: Math.round(process.uptime()),
    timestamp: new Date().toISOString(),
    checks,
  }
})
