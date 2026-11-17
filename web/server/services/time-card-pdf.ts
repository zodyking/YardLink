import { PDFDocument, StandardFonts, rgb } from 'pdf-lib'
import type { TimeCardHeader, TimeCardStop } from '#shared/utils/time-card'
import { timeCardDrawPlan, timeCardPdfY } from '#shared/utils/time-card-layout'
import {
  coerceTimeCardFormBytes,
  loadTimeCardForm,
  TIME_CARD_FORM_PDF,
} from './time-card-forms'

export const coerceTimeCardPdfBytes = coerceTimeCardFormBytes

/** Helvetica is WinAnsi, so fold the punctuation a yard name may carry. */
const PUNCTUATION: Record<string, string> = {
  '\u2010': '-', '\u2011': '-', '\u2012': '-', '\u2013': '-', '\u2014': '-', '\u2015': '-',
  '\u2018': '\'', '\u2019': '\'', '\u201A': ',', '\u201B': '\'',
  '\u201C': '"', '\u201D': '"', '\u201E': '"', '\u2032': '\'', '\u2033': '"',
  '\u2026': '...', '\u00A0': ' ', '\u2022': '-', '\u2212': '-',
}

function winAnsi(text: string): string {
  return text
    .replace(/[\u00A0\u2010-\u2015\u2018-\u201E\u2022\u2026\u2032\u2033\u2212]/g, ch => PUNCTUATION[ch] ?? ' ')
    .replace(/[^\x20-\x7E\u00A1-\u00FF]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
}

/** Overlay filled values on the exact two-page printed short-haul card. */
export async function fillTimeCardPdf(header: TimeCardHeader, stops: TimeCardStop[]): Promise<Uint8Array> {
  const template = await loadTimeCardForm(TIME_CARD_FORM_PDF)
  const pdf = await PDFDocument.load(template)
  const pages = pdf.getPages()
  const page = pages[0]
  if (!page) {
    throw createError({ statusCode: 500, statusMessage: 'Time card template is missing page 1.' })
  }

  const font = await pdf.embedFont(StandardFonts.Helvetica)
  const ink = rgb(0.07, 0.12, 0.2)

  for (const op of timeCardDrawPlan(header, stops)) {
    const text = winAnsi(op.text)
    if (!text) continue
    const draw = (value: string) => page.drawText(value, {
      x: op.x,
      y: timeCardPdfY(op.topY),
      size: op.size,
      font,
      color: ink,
    })
    try {
      draw(text)
    }
    catch {
      const ascii = text.replace(/[^\x20-\x7E]/g, ' ').replace(/\s+/g, ' ').trim()
      if (ascii) draw(ascii)
    }
  }

  return pdf.save({ useObjectStreams: false })
}
