import { createHash } from 'node:crypto'
import { constants } from 'node:fs'
import { access, mkdir, readFile, rm, writeFile } from 'node:fs/promises'
import { dirname, join, resolve, sep } from 'node:path'

/**
 * File storage boundary (spec 10, 29).
 *
 * Files are always private: the browser never receives a guessable public URL.
 * Downloads go through an authenticated server route that checks tenant and
 * role before streaming or issuing a short-lived signed URL.
 */

export interface StoredObject {
  key: string
  size: number
  contentType: string
  checksum: string | null
}

export interface StorageService {
  put(key: string, body: Buffer, contentType: string): Promise<StoredObject>
  get(key: string): Promise<Buffer>
  delete(key: string): Promise<void>
  /** Short-lived, authenticated download URL. */
  signedUrl(key: string, expiresInSeconds?: number): Promise<string>
  healthCheck(): Promise<{ healthy: boolean, message: string }>
}

/** Allowed upload types — validated before a document becomes visible to others. */
export const ALLOWED_MIME_TYPES = [
  'image/jpeg',
  'image/png',
  'image/webp',
  'image/heic',
  'application/pdf',
] as const

export const MAX_UPLOAD_BYTES = 25 * 1024 * 1024

export function assertUploadAllowed(mimeType: string, sizeBytes: number): void {
  if (!(ALLOWED_MIME_TYPES as readonly string[]).includes(mimeType)) {
    throw createError({ statusCode: 415, statusMessage: `Unsupported file type: ${mimeType}` })
  }
  if (sizeBytes > MAX_UPLOAD_BYTES) {
    throw createError({ statusCode: 413, statusMessage: 'File exceeds the 25 MB limit.' })
  }
}

/** Deterministic, tenant-scoped object key. */
export function buildStorageKey(companyId: string, category: string, fileName: string): string {
  const safe = fileName.replace(/[^\w.-]/g, '_').slice(-120)
  return `${companyId}/${category.toLowerCase()}/${Date.now()}-${crypto.randomUUID()}-${safe}`
}

/** Where uploads live. The Docker image mounts a volume here. */
export function dataDirectory(): string {
  return process.env.YARDLINK_DATA_DIR || join(process.cwd(), '.data')
}

/**
 * Files on the server's own disk, under the data volume. Nothing to
 * configure and nothing to run beside the app: the same volume that holds
 * the generated secrets holds the uploads, so one backup covers both.
 */
export class LocalDiskStorageService implements StorageService {
  private root = join(dataDirectory(), 'files')

  private pathFor(key: string): string {
    const full = resolve(this.root, key)
    if (full !== this.root && !full.startsWith(this.root + sep)) {
      throw createError({ statusCode: 400, statusMessage: 'Invalid file key.' })
    }
    return full
  }

  async put(key: string, body: Buffer, contentType: string): Promise<StoredObject> {
    const target = this.pathFor(key)
    await mkdir(dirname(target), { recursive: true })
    await writeFile(target, body)
    return {
      key,
      size: body.byteLength,
      contentType,
      checksum: createHash('sha256').update(body).digest('hex'),
    }
  }

  async get(key: string): Promise<Buffer> {
    try {
      return await readFile(this.pathFor(key))
    }
    catch {
      throw createError({ statusCode: 404, statusMessage: 'File not found.' })
    }
  }

  async delete(key: string): Promise<void> {
    await rm(this.pathFor(key), { force: true })
  }

  /** Downloads always go through the authenticated document route. */
  async signedUrl(key: string): Promise<string> {
    return `/api/documents/file?key=${encodeURIComponent(key)}`
  }

  async healthCheck() {
    try {
      await mkdir(this.root, { recursive: true })
      await access(this.root, constants.W_OK)
      return { healthy: true, message: 'Saved on this server with the rest of the Yard Link data.' }
    }
    catch (error) {
      return {
        healthy: false,
        message: `The data folder is not writable (${error instanceof Error ? error.message : 'unknown error'}).`,
      }
    }
  }
}

let instance: StorageService | undefined

/**
 * Deliberately not named `useStorage` — that identifier belongs to Nitro's
 * built-in unstorage helper.
 */
export function useObjectStorage(): StorageService {
  if (!instance) instance = new LocalDiskStorageService()
  return instance
}
