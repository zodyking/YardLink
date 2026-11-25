import {
  SHIPCSX_BATCH_SIZE,
  SHIPCSX_LOOKUP_URL,
  SHIPCSX_REFERENCE,
  pickShipcsxTerminal,
  wizardShipcsxTerminal,
  chunkShipcsxEquipment,
  cleanShipcsxTerminalNames,
  matchLookupCard,
  matchShipcsxTerminalOption,
  parseShipcsxLookupText,
  shipcsxEquipmentParts,
  shipcsxPageLooksHardBlocked,
  shipcsxPageLooksLikeChallenge,
  shipcsxPageLooksLikeLogin,
  type CsxLookupCard,
} from '#shared/utils/csx-lookup'
import { shipcsxCheckStep, type ShipcsxCheckStepId } from '#shared/utils/shipcsx-check'
import { normalizeContainerNumber } from '#shared/utils/iso6346'
import { peekCompanySettings } from '../utils/settings'

export interface ShipcsxLookupItem {
  equipmentNumber: string
  containerId?: string | null
}

export interface ShipcsxLookupHit extends CsxLookupCard {
  containerId: string | null
  referenceUsed: string
  error: string | null
}

export type ShipcsxLookupStepHandler = (step: ShipcsxCheckStepId) => void

type PlaywrightModule = typeof import('playwright')
type Page = import('playwright').Page
type Locator = import('playwright').Locator

let playwrightModule: PlaywrightModule | null | undefined

const CHROMIUM_ARGS = [
  '--disable-blink-features=AutomationControlled',
  '--no-sandbox',
  '--disable-dev-shm-usage',
  '--disable-gpu',
]

const DESKTOP_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36'
const TYPE_DELAY_MS = 45

function config() {
  // Set in Settings → ShipCSX. Loaded with the company settings.
  return {
    defaultTerminal: peekCompanySettings().shipcsxDefaultTerminal,
  }
}

/** One browser at a time. A check someone is waiting on goes ahead of the background poll. */
let lockHeld = false
const lockWaiters: Array<{ urgent: boolean, start: () => void }> = []

function releaseShipcsxLock() {
  const urgentIndex = lockWaiters.findIndex(waiter => waiter.urgent)
  const [next] = lockWaiters.splice(urgentIndex >= 0 ? urgentIndex : 0, 1)
  if (next) next.start()
  else lockHeld = false
}

async function withShipcsxLock<T>(urgent: boolean, work: () => Promise<T>): Promise<T> {
  if (lockHeld) {
    await new Promise<void>(start => lockWaiters.push({ urgent, start }))
  }
  else {
    lockHeld = true
  }
  try {
    return await work()
  }
  finally {
    releaseShipcsxLock()
  }
}

/** Longest one batch may hold the browser. A hung page must never block every later check. */
const LOOKUP_DEADLINE_MS = 150_000
const CLOSE_DEADLINE_MS = 10_000

function within<T>(promise: Promise<T>, ms: number, message: string): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined
  const deadline = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error(message)), ms)
  })
  return Promise.race([promise, deadline]).finally(() => clearTimeout(timer))
}

async function loadPlaywright(): Promise<PlaywrightModule> {
  if (playwrightModule) return playwrightModule
  if (playwrightModule === null) throw new Error('Playwright is not installed.')
  try {
    playwrightModule = await import('playwright')
    return playwrightModule
  }
  catch {
    playwrightModule = null
    throw new Error('Playwright is not installed. Run npx playwright install chromium.')
  }
}

function pause(min = 160, max = 420) {
  const ms = min + Math.floor(Math.random() * Math.max(1, max - min))
  return new Promise(resolveWait => setTimeout(resolveWait, ms))
}

const STEALTH = `
  Object.defineProperty(navigator, 'webdriver', { get: () => undefined });
  Object.defineProperty(navigator, 'languages', { get: () => ['en-US', 'en'] });
  Object.defineProperty(navigator, 'plugins', { get: () => [1, 2, 3, 4, 5] });
`

async function openPage() {
  const { chromium } = await loadPlaywright()
  const launched = await chromium.launch({
    headless: true,
    args: CHROMIUM_ARGS,
    chromiumSandbox: false,
    timeout: 30_000,
  }).catch(async (first) => {
    const retry = await chromium.launch({
      headless: true,
      args: CHROMIUM_ARGS,
      timeout: 30_000,
      channel: 'chrome',
    }).catch(() => null)
    if (retry) return retry
    const detail = first instanceof Error ? first.message : 'Chromium failed to launch'
    if (/executable|browser|chromium|playwright/i.test(detail)) {
      throw new Error('Playwright Chromium is not installed. The server image needs `npx playwright install chromium`.')
    }
    throw first instanceof Error ? first : new Error(detail)
  })

  const context = await launched.newContext({
    locale: 'en-US',
    timezoneId: 'America/New_York',
    viewport: { width: 1280, height: 900 },
    userAgent: DESKTOP_UA,
  })
  await context.addInitScript(STEALTH)
  const page = await context.newPage()
  page.setDefaultTimeout(20_000)
  return { browser: launched, context, page }
}

async function bodyText(page: Page): Promise<string> {
  return page.locator('body').innerText().catch(() => '')
}

function assertLookupPage(text: string, url: string) {
  if (shipcsxPageLooksHardBlocked(text)) {
    throw new Error('ShipCSX challenged this session. Backing off automatic checks.')
  }
  if (shipcsxPageLooksLikeLogin(text, url)) {
    throw new Error('ShipCSX shipment lookup is not available without a login wall.')
  }
}

/** How long a Cloudflare check may run on its own before we give up on it. Its automatic pass takes a few seconds; an interactive checkbox never passes. */
const CHALLENGE_GRACE_MS = 12_000
const FORM_DEADLINE_MS = 25_000
const HUMAN_CHECK_ERROR = 'ShipCSX asked for a Cloudflare human check. Backing off automatic checks.'

async function waitForLookupForm(page: Page) {
  const started = Date.now()
  let challengeSince: number | null = null
  while (Date.now() - started < FORM_DEADLINE_MS) {
    const text = await bodyText(page)
    const url = page.url()
    if (shipcsxPageLooksHardBlocked(text)) {
      throw new Error('ShipCSX challenged this session. Backing off automatic checks.')
    }
    if (shipcsxPageLooksLikeLogin(text, url)) {
      throw new Error('ShipCSX shipment lookup is not available without a login wall.')
    }
    const title = await page.title().catch(() => '')
    if (shipcsxPageLooksLikeChallenge(`${title}\n${text}`)) {
      challengeSince ??= Date.now()
      if (Date.now() - challengeSince > CHALLENGE_GRACE_MS) {
        console.warn('[shipcsx] cloudflare check did not clear', { url, title })
        throw new Error(HUMAN_CHECK_ERROR)
      }
    }
    else {
      challengeSince = null
      if (await searchButton(page).isVisible().catch(() => false)) return
    }
    await pause(250, 400)
  }
  const leftover = await bodyText(page)
  // What the server's browser actually saw, so a failure here can be diagnosed from the logs.
  console.warn('[shipcsx] lookup form missing', { url: page.url(), title: await page.title().catch(() => ''), snippet: leftover.slice(0, 400) })
  if (shipcsxPageLooksLikeChallenge(leftover)) throw new Error(HUMAN_CHECK_ERROR)
  throw new Error('ShipCSX lookup form did not load. The search button never became available.')
}

function searchButton(page: Page): Locator {
  return page.getByRole('button', { name: /search|continue/i }).first()
    .or(page.locator('ion-button').filter({ hasText: /search|continue/i }).first())
    .or(page.locator('button, [type="submit"]').filter({ hasText: /search|continue/i }).first())
}

function terminalTrigger(page: Page): Locator {
  return page.locator('ion-select').first()
    .or(page.getByRole('combobox').first())
    .or(page.getByLabel(/terminal/i).first())
    .or(page.getByText(/select terminal/i).first())
}

async function nativeTerminalSelect(page: Page): Promise<Locator | null> {
  const selects = page.locator('select')
  const n = await selects.count()
  if (!n) return null
  let bestIndex = 0
  let bestOptions = 0
  for (let i = 0; i < n; i++) {
    const options = await selects.nth(i).locator('option').count()
    if (options > bestOptions) {
      bestIndex = i
      bestOptions = options
    }
  }
  return bestOptions >= 2 ? selects.nth(bestIndex) : selects.first()
}

async function fillControl(locator: Locator, value: string) {
  const handle = locator.first()
  await handle.waitFor({ state: 'attached', timeout: 15_000 })
  const inner = handle.locator('input').first()
  const target = (await inner.count()) ? inner : handle
  await target.click({ timeout: 8_000 })
  await pause(80, 160)
  await target.fill('')
  await target.pressSequentially(value, { delay: TYPE_DELAY_MS })
  await target.evaluate((el, next) => {
    const host = el as HTMLElement
    const input = (host instanceof HTMLInputElement
      ? host
      : host.querySelector?.('input') || host.shadowRoot?.querySelector('input')) as HTMLInputElement | null
    if (!input) return
    const descriptor = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')
    descriptor?.set?.call(input, next)
    input.dispatchEvent(new Event('input', { bubbles: true }))
    input.dispatchEvent(new Event('change', { bubbles: true }))
  }, value)
  await target.blur().catch(() => undefined)
}

async function menuOptionLocators(page: Page): Promise<Locator> {
  return page.getByRole('option')
    .or(page.getByRole('radio'))
    .or(page.locator('ion-alert button, .alert-radio-label, ion-select-option'))
}

async function scrollMenuToOption(page: Page, wanted: string): Promise<boolean> {
  const options = await menuOptionLocators(page)
  const count = await options.count()
  if (!count) return false
  const labels: string[] = []
  for (let i = 0; i < count; i++) {
    labels.push((await options.nth(i).innerText().catch(() => '')).trim())
  }
  const match = matchShipcsxTerminalOption(labels, wanted)
  if (!match) return false
  const index = labels.findIndex(label => label === match)
  const option = options.nth(Math.max(0, index))
  const list = page.locator('[role="listbox"], ion-alert, ion-action-sheet, ion-select-popover, .alert-wrapper').first()
  if (await list.count()) {
    await list.evaluate((el) => {
      el.scrollTop = 0
    })
    await pause(120, 240)
    const targetTop = await option.evaluate(el => (el as HTMLElement).offsetTop).catch(() => 0)
    await list.evaluate((el, top) => {
      el.scrollTop = Math.max(0, top - 80)
    }, targetTop)
    await pause(160, 280)
  }
  await option.scrollIntoViewIfNeeded().catch(() => undefined)
  await pause(120, 220)
  await option.click({ timeout: 10_000 })
  const done = page.getByRole('button', { name: /^(ok|done)$/i }).first()
  if (await done.count()) await done.click().catch(() => undefined)
  return true
}

async function scrollNativeSelect(page: Page, native: Locator, wanted: string) {
  const labels = cleanShipcsxTerminalNames(await native.locator('option').allTextContents())
  const match = matchShipcsxTerminalOption(labels, wanted)
  if (!match) {
    throw new Error(`ShipCSX terminal "${wanted}" was not in the dropdown.`)
  }
  const all = await native.locator('option').allTextContents()
  const index = all.findIndex(label => label.replace(/\s+/g, ' ').trim() === match)
  await native.scrollIntoViewIfNeeded().catch(() => undefined)
  await native.click({ timeout: 8_000 }).catch(() => undefined)
  await native.focus()
  await pause(120, 220)
  await page.keyboard.press('Home')
  const steps = Math.max(0, index)
  for (let i = 0; i < steps; i++) {
    await page.keyboard.press('ArrowDown')
    if (i % 3 === 2) await pause(40, 80)
  }
  await pause(80, 160)
  await page.keyboard.press('Enter')
  await pause(200, 360)
  const selected = await native.inputValue().catch(() => '')
  if (matchShipcsxTerminalOption([selected, match], wanted) !== match) {
    await native.selectOption({ label: match })
  }
}

async function selectTerminal(page: Page, terminal: string) {
  const native = await nativeTerminalSelect(page)
  const trigger = terminalTrigger(page)
  if (await trigger.count()) {
    await trigger.scrollIntoViewIfNeeded().catch(() => undefined)
    await pause(120, 240)
    await trigger.click({ timeout: 15_000 })
    await pause(350, 700)
    if (await scrollMenuToOption(page, terminal)) {
      await pause(250, 500)
      return
    }
    await page.keyboard.press('Escape').catch(() => undefined)
  }
  if (native) {
    await scrollNativeSelect(page, native, terminal)
    return
  }
  throw new Error(`Could not select ShipCSX terminal "${terminal}".`)
}

async function fillReferenceRows(page: Page, count: number, reference: string) {
  const refs = page.locator(
    'input[placeholder*="Pickup" i], input[aria-label*="Reference" i], ion-input[placeholder*="Pickup" i], ion-input[label*="Reference" i]',
  )
  const labeledRef = page.getByLabel(/reference|pickup number/i)
  const all = page.locator('input[type="text"], input:not([type]), ion-input')
  const total = await all.count()
  for (let i = 0; i < count; i++) {
    if (await refs.count()) {
      await fillControl(refs.nth(Math.min(i, await refs.count() - 1)), reference)
    }
    else if (await labeledRef.count()) {
      await fillControl(labeledRef.nth(Math.min(i, await labeledRef.count() - 1)), reference)
    }
    else if (i * 3 + 2 < total) {
      await fillControl(all.nth(i * 3 + 2), reference)
    }
    await pause()
  }
}
async function fillEquipmentRows(page: Page, equipment: string[]) {
  const rows = equipment
    .map(shipcsxEquipmentParts)
    .filter((parts): parts is NonNullable<typeof parts> => Boolean(parts))
  if (!rows.length) return

  const initials = page.locator(
    'input[placeholder*="CSXU" i], input[aria-label*="Initial" i], ion-input[placeholder*="CSXU" i], ion-input[label*="Initial" i]',
  )
  const numbers = page.locator(
    'input[placeholder*="123456"], input[aria-label*="Equipment Number" i], ion-input[placeholder*="123456"], ion-input[label*="Number" i]',
  )
  const labeledInitial = page.getByLabel(/equipment initial|initial/i)
  const labeledNumber = page.getByLabel(/equipment number/i)

  if (await initials.count()) {
    const initialCount = await initials.count()
    const numberCount = await numbers.count()
    for (const [i, row] of rows.entries()) {
      const initialField = initials.nth(Math.min(i, initialCount - 1))
      if (numberCount) {
        await fillControl(initialField, row.initial)
        await pause()
        await fillControl(numbers.nth(Math.min(i, numberCount - 1)), row.number)
        await pause()
      }
      else {
        await fillControl(initialField, `${row.initial}${row.number}`)
        await pause()
      }
    }
    return
  }

  if (await labeledInitial.count() && await labeledNumber.count()) {
    const initialCount = await labeledInitial.count()
    const numberCount = await labeledNumber.count()
    for (const [i, row] of rows.entries()) {
      await fillControl(labeledInitial.nth(Math.min(i, initialCount - 1)), row.initial)
      await pause()
      await fillControl(labeledNumber.nth(Math.min(i, numberCount - 1)), row.number)
      await pause()
    }
    return
  }

  const all = page.locator('input[type="text"], input:not([type]), ion-input')
  const total = await all.count()
  for (const [i, row] of rows.entries()) {
    const base = i * 3
    if (base >= total) break
    await fillControl(all.nth(base), row.initial)
    await pause()
    if (base + 1 < total) {
      await fillControl(all.nth(base + 1), row.number)
      await pause()
    }
  }
}

async function submitSearch(page: Page) {
  const search = searchButton(page)
  if (await search.count()) {
    const enabled = await search.isEnabled({ timeout: 0 }).catch(() => false)
    if (enabled) {
      await search.click({ timeout: 15_000 })
      return
    }
    await search.click({ force: true, timeout: 8_000 }).catch(() => undefined)
  }
  await page.keyboard.press('Enter')
}

async function withLookupPage<T>(work: (page: Page) => Promise<T>): Promise<T> {
  const { browser, context, page } = await openPage()
  const running = work(page)
  // Closing the browser on the deadline makes the abandoned work reject; that is expected.
  running.catch(() => undefined)
  try {
    return await within(running, LOOKUP_DEADLINE_MS, 'ShipCSX took too long to answer.')
  }
  finally {
    await within(context.close(), CLOSE_DEADLINE_MS, 'close').catch(() => undefined)
    await within(browser.close(), CLOSE_DEADLINE_MS, 'close').catch(() => undefined)
  }
}

async function runLookup(
  terminal: string,
  equipment: string[],
  reference: string,
  onStep?: ShipcsxLookupStepHandler,
): Promise<CsxLookupCard[]> {
  let reached: ShipcsxCheckStepId = 'open'
  const step = (id: ShipcsxCheckStepId) => {
    reached = id
    onStep?.(id)
  }
  return withLookupPage(async (page) => {
    try {
      console.info('[shipcsx] lookup', { terminal, count: equipment.length })
      await page.goto(SHIPCSX_LOOKUP_URL, { waitUntil: 'domcontentloaded', timeout: 45_000 })
      await waitForLookupForm(page)
      assertLookupPage(await bodyText(page), page.url())
      step('terminal')
      await selectTerminal(page, terminal)
      step('equipment')
      await fillEquipmentRows(page, equipment)
      step('reference')
      await fillReferenceRows(page, equipment.length, reference)
      step('search')
      await submitSearch(page)
      await page.waitForTimeout(1200)
      step('results')
      const resultsHeading = page.getByText(/Shipment Lookup Results|In-Gate|NOTIFIED/i).first()
      const appeared = await resultsHeading.waitFor({ timeout: 25_000 }).then(() => true).catch(() => false)
      const results = await bodyText(page)
      assertLookupPage(results, page.url())
      if (!appeared && /select terminal|equipment initial|equipment lookup/i.test(results)) {
        console.warn('[shipcsx] search did not return results', { url: page.url(), snippet: results.slice(0, 280) })
        throw new Error('ShipCSX did not return lookup results. Search may still be disabled.')
      }
      return parseShipcsxLookupText(results).cards
    }
    catch (error) {
      const at = shipcsxCheckStep(reached).stepLabel
      if (error instanceof Error && /locator\.|timeout \d+ms exceeded|getByRole/i.test(error.message)) {
        console.warn('[shipcsx] playwright', { at, error: error.message.split('\n')[0] })
        throw new Error(`ShipCSX did not return lookup results. Search may still be disabled. (at ${at})`, { cause: error })
      }
      const message = error instanceof Error ? error.message : 'ShipCSX lookup failed.'
      throw new Error(`${message} (at ${at})`, { cause: error })
    }
  })
}

export async function lookupShipcsxShipments(input: {
  terminal: string
  items: ShipcsxLookupItem[]
  reference?: string
  onStep?: ShipcsxLookupStepHandler
  /** Someone is watching this check; run it before queued background work. */
  urgent?: boolean
}): Promise<ShipcsxLookupHit[]> {
  const terminal = wizardShipcsxTerminal(input.terminal)
  if (!terminal) throw new Error('Choose a CSX location.')
  const items = input.items.filter(item => normalizeContainerNumber(item.equipmentNumber))
  if (!items.length) return []
  const reference = (input.reference ?? SHIPCSX_REFERENCE).trim() || SHIPCSX_REFERENCE

  const hits: ShipcsxLookupHit[] = []
  // The lock is taken per batch, so a long background poll yields to a check
  // someone is waiting on between batches instead of holding it to the end.
  for (const batch of chunkShipcsxEquipment(items, SHIPCSX_BATCH_SIZE)) {
    await withShipcsxLock(input.urgent ?? false, async () => {
      input.onStep?.('open')
      const cards = await runLookup(
        terminal,
        batch.map(item => item.equipmentNumber),
        reference,
        input.onStep,
      )
      for (const item of batch) {
        const card = matchLookupCard(cards, item.equipmentNumber)
        hits.push({
          equipmentNumber: normalizeContainerNumber(item.equipmentNumber),
          containerId: item.containerId ?? null,
          referenceUsed: reference,
          loadEmpty: card?.loadEmpty ?? null,
          waybillDate: card?.waybillDate ?? null,
          inGateReadiness: card?.inGateReadiness ?? null,
          gateWindow: card?.gateWindow ?? null,
          resultTab: card?.resultTab ?? 'NOT_FOUND',
          error: card ? null : 'Not found on ShipCSX for this terminal.',
        })
      }
      await pause(500, 1100)
    })
  }
  return hits
}

export function defaultShipcsxTerminal(): string {
  return pickShipcsxTerminal(config().defaultTerminal)
}
