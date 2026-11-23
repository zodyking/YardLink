import type { PDFFont, PDFPage } from 'pdf-lib'
import { PDFDocument, StandardFonts, rgb } from 'pdf-lib'
import type { TimeCardHeader, TimeCardStop } from '#shared/utils/time-card'
import type { TimeCardBranding, TimeCardDirectoryEntry } from '#shared/utils/time-card-layout'
import {
  clipTimeCardText,
  TIME_CARD_BRANDING_COVERS,
  TIME_CARD_DIRECTORY_COLS,
  TIME_CARD_DIRECTORY_ROW_H,
  TIME_CARD_DIRECTORY_ROWS_PER_PAGE,
  TIME_CARD_DIRECTORY_TOP,
  TIME_CARD_PAGE_HEIGHT,
  TIME_CARD_PAGE_WIDTH,
  timeCardBrandingPlan,
  timeCardDrawPlan,
  timeCardPdfRectY,
  timeCardPdfY,
} from '#shared/utils/time-card-layout'
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

const BLANK_BRANDING: TimeCardBranding = { companyName: '', officePhone: '', dispatchPhone: '', reportingLocation: '' }

function chunkRows<T>(items: readonly T[], size: number): T[][] {
  const out: T[][] = []
  for (let i = 0; i < items.length; i += size) out.push(items.slice(i, i + size) as T[])
  return out
}

/** Overlay filled values on the exact two-page printed short-haul card. */
export async function fillTimeCardPdf(
  header: TimeCardHeader,
  stops: TimeCardStop[],
  branding: TimeCardBranding = BLANK_BRANDING,
  directory: TimeCardDirectoryEntry[] = [],
): Promise<Uint8Array> {
  const template = await loadTimeCardForm(TIME_CARD_FORM_PDF)
  const pdf = await PDFDocument.load(template)
  const pages = pdf.getPages()
  const page = pages[0]
  if (!page) {
    throw createError({ statusCode: 500, statusMessage: 'Time card template is missing page 1.' })
  }

  const font = await pdf.embedFont(StandardFonts.Helvetica)
  const boldFont = await pdf.embedFont(StandardFonts.HelveticaBold)
  const ink = rgb(0.07, 0.12, 0.2)
  const white = rgb(1, 1, 1)

  const drawText = (target: PDFPage, value: string, x: number, topY: number, size: number, useFont: PDFFont) => {
    const text = winAnsi(value)
    if (!text) return
    const run = (v: string) => target.drawText(v, { x, y: timeCardPdfY(topY), size, font: useFont, color: ink })
    try {
      run(text)
    }
    catch {
      const ascii = text.replace(/[^\x20-\x7E]/g, ' ').replace(/\s+/g, ' ').trim()
      if (ascii) run(ascii)
    }
  }

  for (const op of timeCardDrawPlan(header, stops)) {
    drawText(page, op.text, op.x, op.topY, op.size, op.bold ? boldFont : font)
  }

  // The template names a specific predecessor company ("Sensible Logistics
  // Solutions LLC") in its baked-in header image — its name, both of its
  // phone numbers, and its normal reporting location. Cover every one of
  // those regions in white before redrawing this employer's own values, so
  // no company using this app ever hands a driver another company's
  // identity on an official DOT form.
  for (const rect of TIME_CARD_BRANDING_COVERS) {
    page.drawRectangle({
      x: rect.x,
      y: timeCardPdfRectY(rect.topY, rect.height),
      width: rect.width,
      height: rect.height,
      color: white,
    })
  }
  for (const op of timeCardBrandingPlan(branding)) {
    drawText(page, op.text, op.x, op.topY, op.size, op.bold ? boldFont : font)
  }

  // Page 2 of the template is a raster image of that same predecessor
  // company's real yard/terminal directory — 23 real addresses and phone
  // numbers that belong to nobody using this app. Drop it and draw a fresh
  // directory from this company's own saved locations instead.
  pdf.removePage(1)
  const directoryPages = chunkRows(directory, TIME_CARD_DIRECTORY_ROWS_PER_PAGE)
  if (!directoryPages.length) directoryPages.push([])
  directoryPages.forEach((entries, index) => {
    const directoryPage = pdf.addPage([TIME_CARD_PAGE_WIDTH, TIME_CARD_PAGE_HEIGHT])
    drawText(directoryPage, 'LOCATION DIRECTORY', 40, 44, 16, boldFont)
    drawText(directoryPage, branding.companyName, 40, 64, 11, font)
    if (directoryPages.length > 1) {
      drawText(directoryPage, `Page ${index + 1} of ${directoryPages.length}`, TIME_CARD_PAGE_WIDTH - 130, 44, 9, font)
    }
    drawText(directoryPage, 'LOCATION', TIME_CARD_DIRECTORY_COLS.name, 92, 9, boldFont)
    drawText(directoryPage, 'ADDRESS', TIME_CARD_DIRECTORY_COLS.address, 92, 9, boldFont)
    drawText(directoryPage, 'PHONE', TIME_CARD_DIRECTORY_COLS.phone, 92, 9, boldFont)
    directoryPage.drawLine({
      start: { x: 40, y: timeCardPdfY(98) },
      end: { x: TIME_CARD_PAGE_WIDTH - 40, y: timeCardPdfY(98) },
      thickness: 0.75,
      color: ink,
    })
    if (!entries.length) {
      drawText(directoryPage, 'No saved locations yet.', 40, TIME_CARD_DIRECTORY_TOP, 9, font)
      return
    }
    entries.forEach((entry, row) => {
      const topY = TIME_CARD_DIRECTORY_TOP + row * TIME_CARD_DIRECTORY_ROW_H
      drawText(directoryPage, clipTimeCardText(entry.name, 30), TIME_CARD_DIRECTORY_COLS.name, topY, 9, font)
      drawText(directoryPage, clipTimeCardText(entry.address, 54), TIME_CARD_DIRECTORY_COLS.address, topY, 9, font)
      drawText(directoryPage, clipTimeCardText(entry.phone || '-', 18), TIME_CARD_DIRECTORY_COLS.phone, topY, 9, font)
    })
  })

  return pdf.save({ useObjectStreams: false })
}
