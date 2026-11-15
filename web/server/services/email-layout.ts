/**
 * One layout for every email Yard Link sends, in the brand kit colours:
 * Yard Navy, Link Blue, Container Sky, Paper and Mist, set in Open Sans.
 *
 * Email programs ignore stylesheets and block remote images, so the layout is
 * tables with inline styles and the logo is type, not a picture. Every email
 * also carries a plain-text version with the same content.
 */
const NAVY = '#052543'
const LINK_BLUE = '#007DE0'
const SKY = '#5DAEFE'
const PAPER = '#FFFFFF'
const MIST = '#F2F7FA'
const MUTED = '#5F6C75'
const LINE = '#E0E6EA'
const FONT = `'Open Sans', 'Segoe UI', Helvetica, Arial, sans-serif`

export interface EmailContent {
  /** Shown beside the subject in the inbox list. */
  preview: string
  heading: string
  /** Opening paragraphs, plain text. */
  paragraphs: string[]
  /** A short list, e.g. the day's tasks. */
  items?: Array<{ title: string, detail?: string }>
  /** Someone's own words, shown set apart. */
  quote?: { from: string, body: string }
  button?: { label: string, url: string }
  /** Small print under the button. */
  notes?: string[]
  /** Who the email is from, for the footer. */
  companyName: string
}

function escapeHtml(value: string): string {
  return value
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
}

function paragraph(text: string, style: string): string {
  return `<p style="${style}">${escapeHtml(text).replace(/\n/g, '<br>')}</p>`
}

function renderHtml(content: EmailContent): string {
  const body = content.paragraphs
    .map(text => paragraph(text, `margin:0 0 16px;font-size:16px;line-height:1.55;color:${NAVY};`))
    .join('')

  const items = content.items?.length
    ? `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 20px;border:1px solid ${LINE};border-radius:12px;">${
      content.items.map((item, index) => `<tr><td style="padding:12px 16px;${index ? `border-top:1px solid ${LINE};` : ''}font-size:15px;line-height:1.45;color:${NAVY};">
        <strong>${escapeHtml(item.title)}</strong>${item.detail ? `<br><span style="color:${MUTED};">${escapeHtml(item.detail).replace(/\n/g, '<br>')}</span>` : ''}
      </td></tr>`).join('')
    }</table>`
    : ''

  const quote = content.quote
    ? `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 20px;"><tr>
        <td style="padding:14px 16px;background:${MIST};border-left:4px solid ${SKY};border-radius:8px;font-size:15px;line-height:1.5;color:${NAVY};">
          <strong>${escapeHtml(content.quote.from)}</strong><br>${escapeHtml(content.quote.body).replace(/\n/g, '<br>')}
        </td></tr></table>`
    : ''

  const button = content.button
    ? `<table role="presentation" cellpadding="0" cellspacing="0" style="margin:4px 0 20px;"><tr>
        <td style="background:${LINK_BLUE};border-radius:12px;">
          <a href="${escapeHtml(content.button.url)}" style="display:inline-block;padding:14px 28px;font-family:${FONT};font-size:16px;font-weight:700;color:${PAPER};text-decoration:none;">${escapeHtml(content.button.label)}</a>
        </td></tr></table>
      <p style="margin:0 0 16px;font-size:13px;line-height:1.5;color:${MUTED};">If the button does not work, copy this address into your browser:<br><span style="word-break:break-all;color:${LINK_BLUE};">${escapeHtml(content.button.url)}</span></p>`
    : ''

  const notes = (content.notes ?? [])
    .map(text => paragraph(text, `margin:0 0 8px;font-size:13px;line-height:1.5;color:${MUTED};`))
    .join('')

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escapeHtml(content.heading)}</title>
</head>
<body style="margin:0;padding:0;background:${MIST};font-family:${FONT};">
<div style="display:none;max-height:0;overflow:hidden;opacity:0;">${escapeHtml(content.preview)}</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:${MIST};">
  <tr>
    <td align="center" style="padding:32px 16px;">
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;background:${PAPER};border:1px solid ${LINE};border-radius:16px;overflow:hidden;">
        <tr>
          <td style="padding:22px 28px;background:${NAVY};font-family:${FONT};font-size:20px;font-weight:800;letter-spacing:0.04em;color:${PAPER};">
            YARD <span style="color:${SKY};">LINK</span>
          </td>
        </tr>
        <tr>
          <td style="height:4px;background:${LINK_BLUE};font-size:0;line-height:0;">&nbsp;</td>
        </tr>
        <tr>
          <td style="padding:28px;font-family:${FONT};">
            <h1 style="margin:0 0 16px;font-size:22px;line-height:1.3;font-weight:700;color:${NAVY};">${escapeHtml(content.heading)}</h1>
            ${body}${items}${quote}${button}${notes}
          </td>
        </tr>
        <tr>
          <td style="padding:18px 28px;background:${MIST};border-top:1px solid ${LINE};font-family:${FONT};font-size:12px;line-height:1.5;color:${MUTED};">
            Sent by ${escapeHtml(content.companyName)} through Yard Link, container and yard management.
          </td>
        </tr>
      </table>
    </td>
  </tr>
</table>
</body>
</html>`
}

function renderText(content: EmailContent): string {
  const lines: string[] = [content.heading, '', ...content.paragraphs.flatMap(text => [text, ''])]
  for (const [index, item] of (content.items ?? []).entries()) {
    lines.push(`${index + 1}. ${item.title}`)
    if (item.detail) lines.push(`   ${item.detail.replace(/\n/g, '\n   ')}`)
  }
  if (content.items?.length) lines.push('')
  if (content.quote) lines.push(`${content.quote.from}:`, content.quote.body, '')
  if (content.button) lines.push(`${content.button.label}: ${content.button.url}`, '')
  for (const note of content.notes ?? []) lines.push(note)
  lines.push('', `Sent by ${content.companyName} through Yard Link.`)
  return lines.join('\n')
}

export function renderEmail(content: EmailContent): { html: string, text: string } {
  return { html: renderHtml(content), text: renderText(content) }
}
