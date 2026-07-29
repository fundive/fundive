/**
 * Resolves what a Tailwind utility class actually paints, so tests can catch
 * text that lands on a same-or-near-same colored background.
 *
 * This is not guesswork against a hardcoded palette: it reads Tailwind's own
 * `theme.css`, the app's `@theme` seam and — critically — the unlayered
 * "dark retrofit" block in `src/index.css` that re-points `text-brand-900`,
 * `bg-white` and `bg-surface-50` at dark-theme values. That retrofit is
 * exactly what makes the failure mode non-obvious: a class list that reads
 * `bg-rose-50 text-brand-950` looks like dark ink on a pale card in the
 * source, but ships as near-white ink on a pale card.
 *
 * FunDive ships two looks from one stylesheet (`theme.design` in the config
 * picks one at build time), so every rule here is read per theme: the
 * retrofit, the re-tinted `--color-*` vars and the page fill all live behind
 * `:root[data-theme="dark"]`. A palette is therefore built for a *named*
 * theme, and the sweep runs once for each — a color that only fails in the
 * look this deployment doesn't ship is still a bug for the fork that does.
 */

export interface Rgb {
  r: number
  g: number
  b: number
}

export interface Palette {
  /** `--color-*` custom properties, raw (may still contain `var()`). */
  vars: Map<string, string>
  /** Utility classes the app re-points, keyed by exact class name. */
  overrides: Map<string, string>
  /** Utility classes the app re-points by prefix (`[class*="…"]` rules). */
  prefixOverrides: { prefix: string; value: string }[]
  /** What every translucent fill ultimately composites onto. */
  page: Rgb
}

const HEX = /^#([0-9a-f]{3}|[0-9a-f]{6})$/i
const OKLCH = /^oklch\(\s*([\d.]+)%?\s+([\d.]+)\s+([\d.]+)(?:deg)?\s*(?:\/\s*([\d.]+%?)\s*)?\)$/i
const COLOR_MIX = /^color-mix\(\s*in\s+[\w-]+\s*,\s*(.+?)\s+([\d.]+)%\s*,\s*transparent\s*\)$/i
const VAR = /^var\(\s*(--[\w-]+)\s*\)$/

export function parseHex(hex: string): Rgb {
  const body = hex.slice(1)
  const full = body.length === 3 ? body.split('').map(c => c + c).join('') : body
  return {
    r: parseInt(full.slice(0, 2), 16),
    g: parseInt(full.slice(2, 4), 16),
    b: parseInt(full.slice(4, 6), 16),
  }
}

function linearToSrgb(v: number): number {
  const c = v <= 0.0031308 ? v * 12.92 : 1.055 * Math.pow(v, 1 / 2.4) - 0.055
  return Math.round(Math.min(1, Math.max(0, c)) * 255)
}

export function oklchToRgb(lightness: number, chroma: number, hue: number): Rgb {
  const rad = (hue * Math.PI) / 180
  const a = chroma * Math.cos(rad)
  const b = chroma * Math.sin(rad)

  const l = (lightness + 0.3963377774 * a + 0.2158037573 * b) ** 3
  const m = (lightness - 0.1055613458 * a - 0.0638541728 * b) ** 3
  const s = (lightness - 0.0894841775 * a - 1.291485548 * b) ** 3

  return {
    r: linearToSrgb(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
    g: linearToSrgb(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
    b: linearToSrgb(-0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s),
  }
}

export function composite(fg: Rgb, alpha: number, backdrop: Rgb): Rgb {
  return {
    r: Math.round(fg.r * alpha + backdrop.r * (1 - alpha)),
    g: Math.round(fg.g * alpha + backdrop.g * (1 - alpha)),
    b: Math.round(fg.b * alpha + backdrop.b * (1 - alpha)),
  }
}

export function relativeLuminance({ r, g, b }: Rgb): number {
  const chan = (v: number) => {
    const s = v / 255
    return s <= 0.04045 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4
  }
  return 0.2126 * chan(r) + 0.7152 * chan(g) + 0.0722 * chan(b)
}

export function contrastRatio(a: Rgb, b: Rgb): number {
  const la = relativeLuminance(a)
  const lb = relativeLuminance(b)
  return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05)
}

export type Theme = 'light' | 'dark'

const THEME_SCOPE = /^:root\[data-theme=["'](light|dark)["']\]\s*/

/**
 * Which theme a rule belongs to, and the selector with that scope stripped.
 * An unscoped rule applies to both looks; `light` is the unscoped default, so
 * only `dark` (and an explicit `light` scope, should a fork add one) narrows.
 */
function scopeOf(selector: string): { theme: Theme | null; rest: string } {
  const trimmed = selector.trim()
  const scoped = THEME_SCOPE.exec(trimmed)
  if (!scoped) return { theme: null, rest: trimmed }
  return { theme: scoped[1] as Theme, rest: trimmed.slice(scoped[0].length) }
}

/** Undo CSS identifier escaping and drop any trailing pseudo-class. */
function selectorToClass(selector: string): string | null {
  const trimmed = selector.trim()
  const attr = /^\[class\*=["']([^"']+)["']\]$/.exec(trimmed)
  if (attr) return null
  if (!trimmed.startsWith('.')) return null
  const withoutPseudo = trimmed.replace(/(?<!\\):[a-z-]+(?:\([^)]*\))?$/, '')
  return withoutPseudo.slice(1).replace(/\\(.)/g, '$1')
}

function attrPrefix(selector: string): string | null {
  const attr = /^\[class\*=["']([^"']+)["']\]$/.exec(selector.trim())
  return attr ? attr[1] : null
}

function collectVars(css: string, into: Map<string, string>): void {
  for (const [, name, value] of css.matchAll(/(--color-[\w-]+)\s*:\s*([^;]+);/g)) {
    into.set(name, value.trim())
  }
}

/**
 * Rule blocks, selector and body. Nesting (`@media { … }`) falls out for free:
 * the selector pattern cannot span a brace, so an inner rule is matched on its
 * own and the wrapper is skipped. Only safe on hand-written sheets — Tailwind's
 * generated `theme.css` nests `@keyframes` inside its var block.
 */
function blocks(css: string): RegExpMatchArray[] {
  return [...css.replace(/\/\*[\s\S]*?\*\//g, '').matchAll(/([^{}]+)\{([^{}]*)\}/g)]
}

/**
 * The sheet as `theme` sees it: the other look's re-tinted `--color-*` block
 * removed outright, its utility overrides renamed to something no class
 * selector can match, and this look's own scope unwrapped so the rules read
 * like the plain utilities they are overriding.
 */
function scopedCss(appCss: string, theme: Theme): string {
  const other: Theme = theme === 'light' ? 'dark' : 'light'
  const scope = (t: Theme) => `:root\\[data-theme=["']${t}["']\\]`
  return appCss
    .replace(new RegExp(`${scope(other)}\\s*\\{[^{}]*\\}`, 'g'), '')
    .replace(new RegExp(`${scope(other)}\\s+(?=[^\\s{])`, 'g'), '.__inert-')
    .replace(new RegExp(`${scope(theme)}\\s+(?=[^\\s{])`, 'g'), '')
}

/**
 * The retrofit lives outside `@theme`/`@layer` on purpose (it has to beat
 * layered utilities), so a rule is "an override" when its selector names a
 * `bg-*`/`text-*` utility. Everything else in the sheet — `body`, `.glass`,
 * `option` — is not a utility and is skipped.
 */
function collectOverrides(css: string, palette: Palette): void {
  for (const [, selectors, body] of blocks(css)) {
    const decl = /(?:^|;)\s*(?:background-color|background|color)\s*:\s*([^;]+)/.exec(body)
    if (!decl) continue
    const value = decl[1].trim()
    if (value.includes('gradient(')) continue
    for (const selector of selectors.split(',')) {
      const prefix = attrPrefix(selector)
      if (prefix && /^(?:bg|text)-/.test(prefix)) {
        palette.prefixOverrides.push({ prefix, value })
        continue
      }
      const cls = selectorToClass(selector)
      if (cls && /^(?:bg|text)-/.test(cls)) palette.overrides.set(cls, value)
    }
  }
}

/** The page fill this theme paints on `body`, if it declares one. */
function bodyBackground(css: string, theme: Theme): Rgb | null {
  let found: Rgb | null = null
  for (const [, selectors, body] of blocks(css)) {
    const declared = /(?:^|;)\s*background-color\s*:\s*(#[0-9a-f]{3,6})/i.exec(body)
    if (!declared) continue
    for (const selector of selectors.split(',')) {
      const { theme: scoped, rest } = scopeOf(selector)
      if (scoped !== null && scoped !== theme) continue
      if (/(?:^|\s)body$/.test(rest.trim())) found = parseHex(declared[1])
    }
  }
  return found
}

export function readPalette(tailwindThemeCss: string, appCss: string, theme: Theme): Palette {
  const palette: Palette = {
    vars: new Map(),
    overrides: new Map(),
    prefixOverrides: [],
    page: { r: 255, g: 255, b: 255 },
  }
  const scoped = scopedCss(appCss, theme)
  collectVars(tailwindThemeCss, palette.vars)
  collectVars(scoped, palette.vars)
  collectOverrides(scoped, palette)

  const bodyBg = bodyBackground(appCss, theme)
  if (bodyBg) palette.page = bodyBg
  return palette
}

/**
 * Resolves a raw CSS color value to what the eye sees. `backdrop` is what a
 * translucent value composites onto — for a background that is its own
 * ancestor's fill, for text it is the background the text sits on.
 */
export function resolveColorValue(value: string, palette: Palette, backdrop: Rgb, depth = 0): Rgb | null {
  if (depth > 8) return null
  const v = value.trim()
  if (v === 'transparent' || v === 'currentColor' || v === 'inherit' || v === 'currentcolor') return null
  if (v === 'white' || v === '#fff' || v === '#ffffff') return { r: 255, g: 255, b: 255 }
  if (v === 'black') return { r: 0, g: 0, b: 0 }

  if (HEX.test(v)) return parseHex(v)

  const varMatch = VAR.exec(v)
  if (varMatch) {
    const inner = palette.vars.get(varMatch[1])
    return inner ? resolveColorValue(inner, palette, backdrop, depth + 1) : null
  }

  const mix = COLOR_MIX.exec(v)
  if (mix) {
    const base = resolveColorValue(mix[1], palette, backdrop, depth + 1)
    return base ? composite(base, Number(mix[2]) / 100, backdrop) : null
  }

  const oklch = OKLCH.exec(v)
  if (oklch) {
    const rgb = oklchToRgb(Number(oklch[1]) / 100, Number(oklch[2]), Number(oklch[3]))
    if (!oklch[4]) return rgb
    const alpha = oklch[4].endsWith('%') ? Number(oklch[4].slice(0, -1)) / 100 : Number(oklch[4])
    return composite(rgb, alpha, backdrop)
  }

  return null
}

const VARIANT = /^(?:[a-z][\w-]*(?:\[[^\]]*\])?:)+/

/** Strip `hover:`, `sm:`, `group-hover:` … — the painted color is the same. */
export function baseUtility(cls: string): string {
  return cls.replace(VARIANT, '')
}

function overrideFor(cls: string, palette: Palette): string | undefined {
  const exact = palette.overrides.get(cls)
  if (exact) return exact
  return palette.prefixOverrides.find(o => cls.startsWith(o.prefix))?.value
}

function resolveUtility(cls: string, kind: 'bg' | 'text', palette: Palette, backdrop: Rgb): Rgb | null {
  const base = baseUtility(cls)
  if (!base.startsWith(`${kind}-`)) return null

  const override = overrideFor(base, palette)
  if (override) return resolveColorValue(override, palette, backdrop)

  const rest = base.slice(kind.length + 1)
  const [name, alphaPart] = rest.split('/')
  const alpha = alphaPart === undefined ? 1 : Number(alphaPart) / 100
  if (Number.isNaN(alpha)) return null

  let rgb: Rgb | null = null
  if (name === 'white') rgb = { r: 255, g: 255, b: 255 }
  else if (name === 'black') rgb = { r: 0, g: 0, b: 0 }
  else if (/^[a-z]+(?:-\d+)?$/.test(name)) rgb = resolveColorValue(`var(--color-${name})`, palette, backdrop)

  if (!rgb) return null
  return alpha >= 1 ? rgb : composite(rgb, alpha, backdrop)
}

/** The color this class paints as a background, or null if it paints none. */
export function backgroundColorFor(cls: string, palette: Palette, backdrop: Rgb): Rgb | null {
  return resolveUtility(cls, 'bg', palette, backdrop)
}

/** The color this class paints as text, or null if it sets no text color. */
export function textColorFor(cls: string, palette: Palette, backdrop: Rgb): Rgb | null {
  return resolveUtility(cls, 'text', palette, backdrop)
}

/**
 * Floor for text against its background. WCAG AA wants 4.5:1 for body copy;
 * this suite is deliberately looser — it exists to catch text that is
 * invisible or nearly so, not to grade the whole palette. Anything under this
 * is the same color twice with a rounding error between them.
 */
export const MIN_TEXT_CONTRAST = 3
