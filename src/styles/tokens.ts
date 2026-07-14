// Palette tokens — single source of truth for the app's surface styles.
// Components compose these instead of hard-coding class strings, so a component
// never needs to know which design variant is active.
//
// DESIGN VARIANTS. Every token below is `pick(light, dark)`:
//   • 'light' — the light look. Cards are translucent white
//     over navy water; text is dark; nav chrome is deep navy. (Matches the Wix
//     site: light-blue surfaces, navy identity, red accent hairline.)
//   • 'dark'  — the dark ocean look. Cards are frosted glass over a deep
//     ocean-night body; text is light; accents are reef teal / mauve neon.
// The fork picks one in fundive.config.ts (`theme.design`); it is a build-time
// constant here, so `pick()` folds to a single string per build. Both literals
// stay in the source, so Tailwind's scanner generates utilities for whichever
// theme is active. The palette/radius/font/body differences live in
// src/index.css under `:root[data-theme="dark"]`.
//
// The categorical event-type rainbow and red status/Beta signal intentionally
// stay on the raw Tailwind palette in both themes (not tokenized here).

import { siteConfig } from '../config/site'

const DARK = siteConfig.theme.design === 'dark'

/** True when the 'dark' design variant is active. */
export const isDark = DARK

/**
 * Choose the class string for the active design variant. Exported for the rare
 * inline spot that needs a theme-specific literal with no matching token — pass
 * the exact current (light) classes first so 'light' rendering is unchanged,
 * and the dark-theme equivalent second. Both literals stay in the source, so
 * Tailwind's scanner generates whichever the build needs.
 */
export function pick(light: string, dark: string): string {
  return DARK ? dark : light
}

// ── Page surfaces ──────────────────────────────────────────────────
// light: page bg is deep navy (the "water"), cards float on top in white.
// dark:  page is transparent — the fixed ocean body gradient (index.css) is the
//         background, so every tab sits on the same water.
export const PAGE         = pick('bg-brand-900 text-white', 'text-brand-50')

// Light hierarchy for loose text directly on the page (headings, section
// labels, empty states) — not inside a card.
export const PAGE_HEADING = pick('text-white', 'text-white')
export const PAGE_BODY    = pick('text-white/80', 'text-brand-100/80')

// ── Cards & panels ─────────────────────────────────────────────────
// light: translucent white cards over the navy water.
// dark:  frosted glass panels; CARD_ELEVATED adds the reef neon glow.
export const CARD          = pick(
  'bg-white/70 backdrop-blur-md border border-surface-200 rounded-xl',
  'glass glass-hover rounded-2xl',
)
export const CARD_ELEVATED = pick(
  'bg-white/65 backdrop-blur-md border border-accent rounded-2xl shadow-lg',
  'glass glow-teal rounded-2xl',
)

// ── Modals ─────────────────────────────────────────────────────────
export const MODAL_BACKDROP = pick(
  'fixed inset-0 bg-brand-900/60 backdrop-blur-sm z-50',
  'fixed inset-0 bg-brand-950/70 backdrop-blur-sm z-50',
)
export const MODAL_PANEL    = pick(
  'bg-white/75 backdrop-blur-md border border-accent rounded-2xl shadow-2xl',
  'glass glow-mauve rounded-2xl shadow-2xl',
)

// ── Text hierarchy on the card surface ─────────────────────────────
// light: dark ink on translucent-white cards (must stay legible against the
//         navy showing through — brand-950 headings, font-medium body).
// dark:  light ink on dark glass; muted/subtle tiers don't drop below /55.
export const TEXT_HEADING = pick('text-brand-950 font-bold',      'text-white font-bold')
export const TEXT_BODY    = pick('text-brand-950 font-medium',    'text-brand-50/90 font-medium')
export const TEXT_MUTED   = pick('text-brand-900 font-medium',    'text-brand-100/70')
export const TEXT_SUBTLE  = pick('text-brand-900/80 font-medium', 'text-brand-100/55')
export const TEXT_LINK    = pick('text-brand-800 font-semibold hover:underline', 'text-reef-300 font-semibold hover:text-reef-200 hover:underline')
export const TEXT_ERROR   = pick('text-red-700 font-semibold',    'text-red-300 font-semibold')

// ── Text hierarchy on the deep navy chrome (nav bars) ──────────────
export const ON_DEEP_BODY    = pick('text-white/80', 'text-white/80')
export const ON_DEEP_MUTED   = pick('text-white/70', 'text-white/70')
export const ON_DEEP_SUBTLE  = pick('text-white/60', 'text-white/60')
export const ON_DEEP_LINK    = pick(
  'text-amber-300 font-semibold hover:text-amber-200 hover:underline',
  'text-reef-300 font-semibold hover:text-reef-200 hover:underline',
)

// ── Buttons ────────────────────────────────────────────────────────
const BUTTON_BASE = 'font-semibold py-2 rounded-lg transition-colors disabled:opacity-50'
// Primary: light = solid navy; dark = reef teal on dark ink (reads on the glow).
export const BTN_PRIMARY = `${BUTTON_BASE} ${pick('bg-brand-900 hover:bg-brand-950 text-white', 'bg-reef-500 hover:bg-reef-400 text-slate-950')}`
export const BTN_GHOST   = `${BUTTON_BASE} ${pick('border border-brand-900 text-brand-900 hover:bg-surface-100', 'border border-white/20 text-brand-50 hover:bg-white/10')}`
export const BTN_DANGER  = `${BUTTON_BASE} ${pick('bg-surface-100 hover:bg-red-100 text-red-700 border border-accent', 'bg-red-500/15 hover:bg-red-500/25 text-red-200 border border-red-400/40')}`
export const BTN_LIGHT   = `${BUTTON_BASE} ${pick('bg-white text-brand-900 hover:bg-surface-100', 'bg-white/10 hover:bg-white/20 text-brand-50 border border-white/15')}`

// Outline "cancel / dismiss" button used in modal + form footers. Layout width
// (e.g. flex-1) stays at the call site — this token is just the button identity.
export const BTN_SECONDARY = pick(
  'py-2 rounded-lg text-sm font-medium text-brand-900 border border-surface-300 hover:bg-surface-50 disabled:opacity-50',
  'py-2 rounded-lg text-sm font-medium text-brand-50 border border-white/20 hover:bg-white/10 disabled:opacity-50',
)

// Compact inline-action buttons — the same three variants above at row size
// (text-xs · px-3 py-1) for dense action rows like the admin user-card controls,
// where a full-height BTN_* would dominate. inline-flex so a <Link> and a
// <button> line up identically.
const BTN_XS_BASE = 'inline-flex items-center justify-center text-xs font-semibold px-3 py-1 rounded-lg transition-colors disabled:opacity-50'
export const BTN_XS_PRIMARY = `${BTN_XS_BASE} ${pick('bg-brand-900 hover:bg-brand-950 text-white', 'bg-reef-500 hover:bg-reef-400 text-slate-950')}`
export const BTN_XS_GHOST   = `${BTN_XS_BASE} ${pick('border border-brand-900 text-brand-900 hover:bg-surface-100', 'border border-white/20 text-brand-50 hover:bg-white/10')}`
export const BTN_XS_DANGER  = `${BTN_XS_BASE} ${pick('bg-surface-100 hover:bg-red-100 text-red-700 border border-accent', 'bg-red-500/15 hover:bg-red-500/25 text-red-200 border border-red-400/40')}`

// ── Inputs ─────────────────────────────────────────────────────────
export const INPUT       = pick(
  'w-full bg-white border border-surface-300 rounded-lg px-3 py-2 text-brand-900 focus:outline-none focus:border-brand-900',
  'w-full bg-white/5 border border-white/15 rounded-lg px-3 py-2 text-brand-50 placeholder:text-brand-100/40 focus:outline-none focus:border-reef-400',
)
export const INPUT_LABEL = pick('block text-sm text-brand-900 mb-1', 'block text-sm text-brand-100 mb-1')

// ── Inline error notes ─────────────────────────────────────────────
// ERROR_NOTE sits on the navy chrome; ERROR_NOTE_LIGHT inside a card. In dark
// both live on dark glass, so both are light-red on a translucent red wash.
export const ERROR_NOTE       = pick(
  'text-xs text-red-200 bg-red-900/50 border border-accent rounded-md p-2',
  'text-xs text-red-200 bg-red-900/40 border border-accent rounded-md p-2',
)
export const ERROR_NOTE_LIGHT = pick(
  'text-xs text-red-700 bg-red-50 border border-accent rounded px-2 py-1',
  'text-xs text-red-200 bg-red-900/30 border border-red-400/40 rounded px-2 py-1',
)

// ── Navigation chrome ──────────────────────────────────────────────
// light: solid navy bars with a red hairline.
// dark:  frosted "waybar" glass bars with a white hairline.
export const NAV_BAR    = pick(
  'bg-brand-950 border-b border-accent px-4 py-3 flex items-center justify-between',
  'waybar border-b border-white/10 px-4 py-3 flex items-center justify-between',
)
export const NAV_BOTTOM = pick(
  'fixed bottom-0 left-0 right-0 bg-brand-950 border-t border-accent flex justify-around py-2',
  'fixed bottom-0 left-0 right-0 waybar border-t border-white/10 flex justify-around py-2 z-40',
)
