/**
 * QR code generator (byte mode, error-correction level M, versions 1–10).
 *
 * Written in-house so the employer connection code needs no third-party
 * package and no outside service: the server draws the code itself. Level M
 * at version 10 carries 213 bytes, far more than a server address needs.
 */

interface VersionSpec {
  ecPerBlock: number
  /** [blockCount, dataCodewordsPerBlock] groups. */
  groups: Array<[number, number]>
  align: number[]
}

const VERSIONS: VersionSpec[] = [
  { ecPerBlock: 10, groups: [[1, 16]], align: [] },
  { ecPerBlock: 16, groups: [[1, 28]], align: [6, 18] },
  { ecPerBlock: 26, groups: [[1, 44]], align: [6, 22] },
  { ecPerBlock: 18, groups: [[2, 32]], align: [6, 26] },
  { ecPerBlock: 24, groups: [[2, 43]], align: [6, 30] },
  { ecPerBlock: 16, groups: [[4, 27]], align: [6, 34] },
  { ecPerBlock: 18, groups: [[4, 31]], align: [6, 22, 38] },
  { ecPerBlock: 22, groups: [[2, 38], [2, 39]], align: [6, 24, 42] },
  { ecPerBlock: 22, groups: [[3, 36], [2, 37]], align: [6, 26, 46] },
  { ecPerBlock: 26, groups: [[4, 43], [1, 44]], align: [6, 28, 50] },
]

/* --- GF(256) arithmetic for Reed–Solomon --- */
const EXP = new Uint8Array(512)
const LOG = new Uint8Array(256)
{
  let x = 1
  for (let i = 0; i < 255; i += 1) {
    EXP[i] = x
    LOG[x] = i
    x <<= 1
    if (x & 0x100) x ^= 0x11d
  }
  for (let i = 255; i < 512; i += 1) EXP[i] = EXP[i - 255]!
}

function gfMul(a: number, b: number): number {
  if (a === 0 || b === 0) return 0
  return EXP[LOG[a]! + LOG[b]!]!
}

function rsGenerator(degree: number): number[] {
  let poly = [1]
  for (let i = 0; i < degree; i += 1) {
    const next = new Array<number>(poly.length + 1).fill(0)
    for (let j = 0; j < poly.length; j += 1) {
      next[j] = next[j]! ^ poly[j]!
      next[j + 1] = next[j + 1]! ^ gfMul(poly[j]!, EXP[i]!)
    }
    poly = next
  }
  return poly
}

function rsRemainder(data: number[], degree: number): number[] {
  const generator = rsGenerator(degree)
  const result = new Array<number>(degree).fill(0)
  for (const byte of data) {
    const factor = byte ^ result.shift()!
    result.push(0)
    for (let i = 0; i < degree; i += 1) {
      result[i] = result[i]! ^ gfMul(generator[i + 1]!, factor)
    }
  }
  return result
}

function utf8Bytes(text: string): number[] {
  return [...new TextEncoder().encode(text)]
}

function dataCapacity(spec: VersionSpec): number {
  return spec.groups.reduce((sum, [count, size]) => sum + count * size, 0)
}

function bchRemainder(value: number, generator: number, generatorBits: number, totalBits: number): number {
  let rem = value << (totalBits - (totalBits - generatorBits + 1))
  for (let bit = totalBits - 1; bit >= generatorBits - 1; bit -= 1) {
    if ((rem >>> bit) & 1) rem ^= generator << (bit - (generatorBits - 1))
  }
  return rem
}

/** Encode text and return the module matrix (`true` = dark), without a quiet zone. */
export function qrMatrix(text: string): boolean[][] {
  const bytes = utf8Bytes(text)

  let version = 0
  for (let v = 1; v <= VERSIONS.length; v += 1) {
    const countBits = v <= 9 ? 8 : 16
    const needed = Math.ceil((4 + countBits + bytes.length * 8) / 8)
    if (needed <= dataCapacity(VERSIONS[v - 1]!)) {
      version = v
      break
    }
  }
  if (!version) throw new Error('That text is too long for a QR code.')

  const spec = VERSIONS[version - 1]!
  const capacity = dataCapacity(spec)

  /* --- Bit stream: mode, length, data, terminator, pad --- */
  const bits: number[] = []
  const push = (value: number, length: number) => {
    for (let i = length - 1; i >= 0; i -= 1) bits.push((value >>> i) & 1)
  }
  push(0b0100, 4)
  push(bytes.length, version <= 9 ? 8 : 16)
  for (const byte of bytes) push(byte, 8)
  push(0, Math.min(4, capacity * 8 - bits.length))
  while (bits.length % 8) bits.push(0)

  const codewords: number[] = []
  for (let i = 0; i < bits.length; i += 8) {
    let byte = 0
    for (let j = 0; j < 8; j += 1) byte = (byte << 1) | bits[i + j]!
    codewords.push(byte)
  }
  for (let pad = 0; codewords.length < capacity; pad += 1) codewords.push(pad % 2 ? 0x11 : 0xec)

  /* --- Split into blocks, add error correction, interleave --- */
  const dataBlocks: number[][] = []
  const ecBlocks: number[][] = []
  let offset = 0
  for (const [count, size] of spec.groups) {
    for (let i = 0; i < count; i += 1) {
      const block = codewords.slice(offset, offset + size)
      offset += size
      dataBlocks.push(block)
      ecBlocks.push(rsRemainder(block, spec.ecPerBlock))
    }
  }
  const stream: number[] = []
  const longest = Math.max(...dataBlocks.map(block => block.length))
  for (let i = 0; i < longest; i += 1) {
    for (const block of dataBlocks) if (i < block.length) stream.push(block[i]!)
  }
  for (let i = 0; i < spec.ecPerBlock; i += 1) {
    for (const block of ecBlocks) stream.push(block[i]!)
  }

  /* --- Function patterns --- */
  const size = version * 4 + 17
  const modules: boolean[][] = Array.from({ length: size }, () => new Array<boolean>(size).fill(false))
  const reserved: boolean[][] = Array.from({ length: size }, () => new Array<boolean>(size).fill(false))
  const set = (row: number, col: number, dark: boolean) => {
    if (row < 0 || col < 0 || row >= size || col >= size) return
    modules[row]![col] = dark
    reserved[row]![col] = true
  }

  const finder = (row: number, col: number) => {
    for (let dr = -1; dr <= 7; dr += 1) {
      for (let dc = -1; dc <= 7; dc += 1) {
        const inside = dr >= 0 && dr <= 6 && dc >= 0 && dc <= 6
        const ring = dr === 0 || dr === 6 || dc === 0 || dc === 6
        const core = dr >= 2 && dr <= 4 && dc >= 2 && dc <= 4
        set(row + dr, col + dc, inside && (ring || core))
      }
    }
  }
  finder(0, 0)
  finder(0, size - 7)
  finder(size - 7, 0)

  for (const row of spec.align) {
    for (const col of spec.align) {
      if (reserved[row]![col]) continue
      for (let dr = -2; dr <= 2; dr += 1) {
        for (let dc = -2; dc <= 2; dc += 1) {
          set(row + dr, col + dc, Math.max(Math.abs(dr), Math.abs(dc)) !== 1)
        }
      }
    }
  }

  // Timing lines go on after alignment: two alignment centres sit on them.
  for (let i = 8; i < size - 8; i += 1) {
    if (!reserved[6]![i]) set(6, i, i % 2 === 0)
    if (!reserved[i]![6]) set(i, 6, i % 2 === 0)
  }

  // Reserve format areas, plus the always-dark module.
  for (let i = 0; i < 9; i += 1) {
    if (!reserved[8]![i]) set(8, i, false)
    if (!reserved[i]![8]) set(i, 8, false)
  }
  for (let i = 0; i < 8; i += 1) {
    set(8, size - 1 - i, false)
    set(size - 1 - i, 8, false)
  }
  set(size - 8, 8, true)

  if (version >= 7) {
    const rem = bchRemainder(version, 0x1f25, 13, 18)
    const info = (version << 12) | rem
    for (let i = 0; i < 18; i += 1) {
      const dark = ((info >>> i) & 1) === 1
      const a = Math.floor(i / 3)
      const b = size - 11 + (i % 3)
      set(a, b, dark)
      set(b, a, dark)
    }
  }

  /* --- Data placement, zig-zag from the bottom-right --- */
  let bitIndex = 0
  const totalBits = stream.length * 8
  let upward = true
  for (let right = size - 1; right >= 1; right -= 2) {
    if (right === 6) right = 5
    for (let step = 0; step < size; step += 1) {
      const row = upward ? size - 1 - step : step
      for (let j = 0; j < 2; j += 1) {
        const col = right - j
        if (reserved[row]![col]) continue
        let dark = false
        if (bitIndex < totalBits) {
          dark = ((stream[bitIndex >>> 3]! >>> (7 - (bitIndex & 7))) & 1) === 1
          bitIndex += 1
        }
        modules[row]![col] = dark
      }
    }
    upward = !upward
  }

  /* --- Mask 0 ((row + col) % 2 === 0) and its format bits --- */
  const mask = 0
  for (let row = 0; row < size; row += 1) {
    for (let col = 0; col < size; col += 1) {
      if (!reserved[row]![col] && (row + col) % 2 === 0) modules[row]![col] = !modules[row]![col]
    }
  }

  const formatData = (0b00 << 3) | mask // level M
  const format = ((formatData << 10) | bchRemainder(formatData, 0x537, 11, 15)) ^ 0x5412
  const formatBit = (i: number) => ((format >>> i) & 1) === 1
  for (let i = 0; i <= 5; i += 1) modules[8]![i] = formatBit(14 - i)
  modules[8]![7] = formatBit(8)
  modules[8]![8] = formatBit(7)
  modules[7]![8] = formatBit(6)
  for (let i = 0; i <= 5; i += 1) modules[5 - i]![8] = formatBit(5 - i)
  for (let i = 0; i <= 6; i += 1) modules[size - 1 - i]![8] = formatBit(14 - i)
  for (let i = 0; i <= 7; i += 1) modules[8]![size - 8 + i] = formatBit(7 - i)

  return modules
}

/** Standalone SVG with a four-module quiet zone. */
export function qrSvg(text: string, options: { dark?: string, light?: string } = {}): string {
  const matrix = qrMatrix(text)
  const quiet = 4
  const size = matrix.length + quiet * 2
  let path = ''
  for (let row = 0; row < matrix.length; row += 1) {
    for (let col = 0; col < matrix.length; col += 1) {
      if (matrix[row]![col]) path += `M${col + quiet} ${row + quiet}h1v1h-1z`
    }
  }
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${size} ${size}" shape-rendering="crispEdges">`
    + `<rect width="${size}" height="${size}" fill="${options.light ?? '#FFFFFF'}"/>`
    + `<path d="${path}" fill="${options.dark ?? '#052543'}"/></svg>`
}
