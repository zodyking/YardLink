import { describe, expect, it } from 'vitest'

import { buildConnectLink, parseConnectLink } from '../shared/utils/connect'
import { qrMatrix, qrSvg } from '../shared/utils/qr'

describe('employer connection link', () => {
  it('round-trips the server address and company name', () => {
    const link = buildConnectLink({ server: 'https://yard.example.com:8443', name: 'Acme Drayage & Co' })
    expect(link.startsWith('yardlink://connect?')).toBe(true)
    expect(parseConnectLink(link)).toEqual({ server: 'https://yard.example.com:8443', name: 'Acme Drayage & Co' })
  })

  it('carries nothing but the address and name', () => {
    const link = buildConnectLink({ server: 'https://yard.example.com', name: 'Acme' })
    const keys = [...new URLSearchParams(link.split('?')[1]).keys()]
    expect(keys).toEqual(['server', 'name'])
  })

  it('accepts a server address typed by hand', () => {
    expect(parseConnectLink('yard.example.com')).toEqual({ server: 'https://yard.example.com', name: '' })
    expect(parseConnectLink('http://192.168.1.40:3847/login')).toEqual({ server: 'http://192.168.1.40:3847', name: '' })
  })

  it('rejects other schemes and empty input', () => {
    expect(parseConnectLink('')).toBeNull()
    expect(parseConnectLink('yardlink://connect')).toBeNull()
    expect(parseConnectLink('yardlink://connect?server=ftp%3A%2F%2Fx')).toBeNull()
  })
})

describe('qr generator', () => {
  it('sizes the symbol by version and draws the three finder patterns', () => {
    const small = qrMatrix('A')
    expect(small).toHaveLength(21)
    const size = small.length
    for (const [row, col] of [[0, 0], [0, size - 7], [size - 7, 0]] as const) {
      expect(small[row]![col]).toBe(true)
      expect(small[row + 1]![col + 1]).toBe(false)
      expect(small[row + 3]![col + 3]).toBe(true)
    }
    expect(qrMatrix('x'.repeat(200))).toHaveLength(57)
  })

  it('refuses text that will not fit', () => {
    expect(() => qrMatrix('x'.repeat(400))).toThrow()
  })

  it('renders a standalone svg', () => {
    const svg = qrSvg('yardlink://connect?server=https%3A%2F%2Fyard.example.com')
    expect(svg.startsWith('<svg')).toBe(true)
    expect(svg).toContain('viewBox')
  })
})
