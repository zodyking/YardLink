import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process'
import { existsSync } from 'node:fs'
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createInterface, type Interface } from 'node:readline'

/**
 * Document-scan boundary: turns a phone photo of a paper document into a
 * clean, flat, evenly-lit "scanned" image — still a plain image (JPEG), so
 * it goes out over SMS/MMS the same way a photo always has. Runs the same
 * way OCR does (./openocr.ts): a persistent Python worker, JSON lines over
 * stdin/stdout, so the process — and anything it needs to warm up — is not
 * paid for on every photo.
 */

export const DOCSCAN_ENGINE = 'docscan-classical'

export interface DocScanResult {
  ok: boolean
  image: Buffer | null
  engine: string
  engineVersion: string | null
  width: number | null
  height: number | null
  boundary: 'perspective' | 'deskew' | null
  latencyMs: number
  error?: string
}

export interface DocScanHealth {
  healthy: boolean
  engine: string
  message: string
}

type Pending = {
  id: string
  resolve: (value: Record<string, unknown>) => void
  reject: (error: Error) => void
  timer: ReturnType<typeof setTimeout>
}

function workerPath(): string | null {
  const candidates = [
    process.env.DOCSCAN_WORKER,
    process.env.NUXT_DOCSCAN_WORKER,
    join(process.cwd(), 'server/docscan/docscan_worker.py'),
    '/app/docscan/docscan_worker.py',
  ]
  return candidates.find((path): path is string => Boolean(path && existsSync(path))) ?? null
}

function pythonBin(): string {
  return process.env.DOCSCAN_PYTHON || process.env.NUXT_DOCSCAN_PYTHON || 'python3'
}

function imageExtension(buffer: Buffer): 'jpg' | 'png' | 'webp' {
  if (buffer.length >= 3 && buffer[0] === 0xff && buffer[1] === 0xd8) return 'jpg'
  if (buffer.length >= 8 && buffer[0] === 0x89 && buffer[1] === 0x50) return 'png'
  if (buffer.length >= 12 && buffer.subarray(8, 12).toString('ascii') === 'WEBP') return 'webp'
  return 'jpg'
}

class DocScanWorker {
  private child: ChildProcessWithoutNullStreams | null = null
  private reader: Interface | null = null
  private ready = false
  private starting: Promise<void> | null = null
  private seq = 0
  private inflight = new Map<string, Pending>()
  private chain: Promise<unknown> = Promise.resolve()

  async health(): Promise<DocScanHealth> {
    const script = workerPath()
    if (!script) {
      return { healthy: false, engine: DOCSCAN_ENGINE, message: 'docscan worker script is missing.' }
    }
    try {
      await this.request({ cmd: 'ping' }, 8_000)
      return { healthy: true, engine: DOCSCAN_ENGINE, message: 'Document scan cleanup is ready.' }
    }
    catch (error) {
      return {
        healthy: false,
        engine: DOCSCAN_ENGINE,
        message: error instanceof Error ? error.message : 'Document scan worker did not respond.',
      }
    }
  }

  /**
   * Runs the restore pipeline once on a captured photo and returns the
   * cleaned-up JPEG bytes. Never throws for an ordinary restore failure —
   * callers should fall back to storing the original photo untouched
   * rather than lose the driver's photo over a cleanup glitch.
   */
  async restore(image: Buffer, options: { quality?: number, timeoutMs?: number } = {}): Promise<DocScanResult> {
    const started = Date.now()
    const dir = await mkdtemp(join(tmpdir(), 'docscan-'))
    const inPath = join(dir, `in.${imageExtension(image)}`)
    const outPath = join(dir, 'out.jpg')
    try {
      await writeFile(inPath, image)
      const reply = await this.request(
        { cmd: 'restore', image_path: inPath, out_path: outPath, quality: options.quality ?? 90 },
        options.timeoutMs ?? 30_000,
      )
      if (!reply.ok) {
        return {
          ok: false,
          image: null,
          engine: DOCSCAN_ENGINE,
          engineVersion: null,
          width: null,
          height: null,
          boundary: null,
          latencyMs: Date.now() - started,
          error: typeof reply.error === 'string' ? reply.error : 'Document scan failed.',
        }
      }
      const restored = await readFile(outPath)
      const meta = (reply.meta ?? {}) as { boundary?: string }
      return {
        ok: true,
        image: restored,
        engine: typeof reply.engine === 'string' ? reply.engine : DOCSCAN_ENGINE,
        engineVersion: typeof reply.engineVersion === 'string' ? reply.engineVersion : null,
        width: typeof reply.width === 'number' ? reply.width : null,
        height: typeof reply.height === 'number' ? reply.height : null,
        boundary: meta.boundary === 'perspective' || meta.boundary === 'deskew' ? meta.boundary : null,
        latencyMs: Date.now() - started,
      }
    }
    catch (error) {
      return {
        ok: false,
        image: null,
        engine: DOCSCAN_ENGINE,
        engineVersion: null,
        width: null,
        height: null,
        boundary: null,
        latencyMs: Date.now() - started,
        error: error instanceof Error ? error.message : 'Document scan worker is not available.',
      }
    }
    finally {
      await rm(dir, { recursive: true, force: true })
    }
  }

  private request(payload: Record<string, unknown>, timeoutMs: number): Promise<Record<string, unknown>> {
    const run = async () => {
      await this.ensure()
      const id = String(++this.seq)
      const child = this.child
      if (!child) throw new Error('Document scan worker is not running.')

      return await new Promise<Record<string, unknown>>((resolve, reject) => {
        const timer = setTimeout(() => {
          this.inflight.delete(id)
          reject(new Error(`Document scan timed out after ${timeoutMs}ms`))
        }, timeoutMs)
        this.inflight.set(id, { id, resolve, reject, timer })
        child.stdin.write(`${JSON.stringify({ id, ...payload })}\n`, (error) => {
          if (!error) return
          clearTimeout(timer)
          this.inflight.delete(id)
          reject(error)
        })
      })
    }

    const next = this.chain.then(run, run)
    this.chain = next.then(() => undefined, () => undefined)
    return next
  }

  private async ensure(): Promise<void> {
    if (this.ready && this.child && !this.child.killed) return
    if (this.starting) return this.starting
    this.starting = this.spawnWorker().finally(() => {
      this.starting = null
    })
    return this.starting
  }

  private async spawnWorker(): Promise<void> {
    const script = workerPath()
    if (!script) {
      throw new Error('Document scan worker script was not found. Install the app with server/docscan/docscan_worker.py.')
    }

    await new Promise<void>((resolve, reject) => {
      const child = spawn(pythonBin(), ['-u', script], {
        stdio: ['pipe', 'pipe', 'pipe'],
        env: { ...process.env, PYTHONUNBUFFERED: '1' },
      })

      this.child = child
      this.ready = false
      this.reader = createInterface({ input: child.stdout })

      child.stderr.on('data', (chunk: Buffer) => {
        const text = chunk.toString('utf8').trim()
        if (text) console.warn('[docscan]', text)
      })

      const bootTimer = setTimeout(() => {
        reject(new Error('Document scan worker did not become ready.'))
        this.kill()
      }, 20_000)

      let settled = false
      this.reader.on('line', (line) => {
        if (!settled) {
          try {
            const msg = JSON.parse(line) as { ok?: boolean, event?: string, error?: string }
            if (msg.event === 'ready' && msg.ok) {
              settled = true
              clearTimeout(bootTimer)
              this.ready = true
              resolve()
              return
            }
            if (msg.ok === false) {
              settled = true
              clearTimeout(bootTimer)
              reject(new Error(msg.error || 'Document scan worker failed to start.'))
              this.kill()
              return
            }
          }
          catch {
            // Non-JSON boot noise is ignored; the ready event is JSON.
          }
        }
        if (this.ready) this.onLine(line)
      })

      child.on('error', (error) => {
        clearTimeout(bootTimer)
        this.ready = false
        reject(error)
      })

      child.on('close', (code) => {
        this.ready = false
        this.child = null
        const err = new Error(`Document scan worker exited (${code ?? 'null'}).`)
        for (const pending of this.inflight.values()) {
          clearTimeout(pending.timer)
          pending.reject(err)
        }
        this.inflight.clear()
      })
    })
  }

  private onLine(line: string) {
    const trimmed = line.trim()
    if (!trimmed) return
    let msg: Record<string, unknown> & { id?: string, event?: string }
    try {
      msg = JSON.parse(trimmed)
    }
    catch {
      return
    }

    if (msg.event === 'ready') {
      this.ready = Boolean(msg.ok)
      return
    }

    const pending = msg.id ? this.inflight.get(String(msg.id)) : undefined
    if (!pending) return
    this.inflight.delete(pending.id)
    clearTimeout(pending.timer)
    pending.resolve(msg)
  }

  private kill() {
    this.ready = false
    this.reader?.close()
    this.reader = null
    this.child?.kill('SIGKILL')
    this.child = null
  }
}

let instance: DocScanWorker | undefined

export function useDocScanWorker(): DocScanWorker {
  if (!instance) instance = new DocScanWorker()
  return instance
}
