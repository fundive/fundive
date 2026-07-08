// Event / destination photos are self-hosted under public/imgs/media/. The
// catalog stores only the original image reference (a `wix:image://…` ref from
// imported data, or a plain URL); we resolve it to a displayable URL here so
// there's no CDN dependency at runtime (nothing to add to the CSP img-src beyond
// 'self'). A fork drops its own optimized `.webp` copies into public/imgs/media/
// (see that folder's README); an event with no matching image falls back to a
// gradient card and never breaks.

/** Slugify a Wix media id segment (e.g. `b37fef_abc~mv2.jpg`) to a filename. */
function slug(seg: string): string {
  return seg.replace(/[^a-zA-Z0-9]/g, '_')
}

/** Media id segment from a `wix:image://v1/<seg>/<filename>#…` ref. */
export function wixMediaId(ref: string | null | undefined): string | null {
  if (!ref || !ref.startsWith('wix:image://')) return null
  const seg = ref.replace(/^wix:image:\/\/v1\//, '').split('#')[0].split('/')[0]
  return seg ? slug(seg) : null
}

/**
 * Resolve a stored image reference to a displayable URL, or null when there's
 * nothing usable. Handles the two shapes the catalog stores:
 *   • `wix:image://…` refs  → the local /imgs/media/<slug>.webp copy
 *   • plain http(s) URLs    → passed through as-is
 */
export function resolveImageUrl(ref: string | null | undefined): string | null {
  if (!ref) return null
  const trimmed = ref.trim()
  if (!trimmed) return null
  const id = wixMediaId(trimmed)
  if (id) return `/imgs/media/${id}.webp`
  if (/^https?:\/\//.test(trimmed)) return trimmed
  return null
}
