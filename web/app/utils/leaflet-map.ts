
type LeafletModule = typeof import('leaflet')

/** Leaflet, loaded in the browser only. */
export async function loadLeaflet(): Promise<LeafletModule> {
  const mod = await import('leaflet')
  return (mod.default ?? mod) as LeafletModule
}

export function waitForMapSize(
  el: HTMLElement,
  isCancelled: () => boolean,
  timeoutMs = 2500,
): Promise<boolean> {
  if (el.clientWidth > 8 && el.clientHeight > 8) return Promise.resolve(true)

  return new Promise((resolve) => {
    let settled = false
    const finish = (ok: boolean) => {
      if (settled) return
      settled = true
      observer.disconnect()
      clearTimeout(timer)
      resolve(ok)
    }

    const observer = new ResizeObserver(() => {
      if (isCancelled()) {
        finish(false)
        return
      }
      if (el.clientWidth > 8 && el.clientHeight > 8) finish(true)
    })
    observer.observe(el)

    const timer = setTimeout(() => {
      finish(el.clientWidth > 8 && el.clientHeight > 8)
    }, timeoutMs)
  })
}

export function observeMapSize(
  el: HTMLElement,
  onResize: () => void,
): () => void {
  const observer = new ResizeObserver(() => {
    if (el.clientWidth > 8 && el.clientHeight > 8) onResize()
  })
  observer.observe(el)
  return () => observer.disconnect()
}
