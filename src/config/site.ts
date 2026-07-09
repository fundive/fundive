import { siteConfig as raw } from 'virtual:fundive-config'
export { CONFIG_CONTRACT_VERSION } from './contract'

// Shop configuration contract. `fundive.config.ts` at the repo root holds the
// values (pure data, no imports, so every runtime can read it); this file is the
// typed handle the app imports — `import { siteConfig } from '@/config/site'` (or
// a relative path). The `: SiteConfig` annotation below is what type-checks the
// fork's config: a missing or mistyped field fails the build here. The zod schema
// (src/config/site.schema.ts) does the same check at runtime for the test suite
// and the vite build guard.

export interface SiteIdentity {
  /** The open-source app name (shared by all shops), e.g. "FunDive". */
  appName: string
  /** This shop's full name, e.g. "Acme Divers". */
  shopName: string
  /** Short brand name for tight UI (push titles, badges). */
  shortName: string
  /** Meta description / PWA description. */
  description: string
  /** Alt text for the logo image. */
  logoAlt: string
}

export interface SiteContact {
  /** Public support / contact email. */
  email: string
  phone: string
  address: string
  mapsUrl: string
  lineUrl: string
  whatsappUrl: string
  paypalLink: string
}

export interface SiteUrls {
  /** Public marketing site, no trailing slash. */
  site: string
  /** The deployed app origin, no trailing slash. */
  app: string
  /** External radio stream, no trailing slash. Optional — omit if unused. */
  radio?: string
}

/**
 * Languages the app ships translations for. Core-owned: a fork picks one via
 * `locale.language`, it does not add its own. Extend this union (and the zod
 * enum in site.schema.ts, plus a catalog under src/i18n/messages) to add a
 * language. See docs/i18n.md.
 */
export type SupportedLanguage = 'en' | 'zh-TW' | 'ja'

export interface SiteLocale {
  /** IANA timezone, e.g. "Asia/Taipei". */
  timezone: string
  /** ISO 4217 currency code used as the code-side default, e.g. "TWD". */
  currency: string
  /** Human-facing currency label, e.g. "NTD". */
  currencyLabel: string
  /** The single language the whole app renders in for this deployment. */
  language: SupportedLanguage
}

export interface SiteTheme {
  /** PWA manifest + index.html theme-color. */
  themeColor: string
  /** PWA manifest background color (splash). */
  backgroundColor: string
  /**
   * Visual design variant, applied as `data-theme` on <html> at startup.
   *   'light' — the light look (white cards on navy). Default.
   *   'dark'  — the dark ocean look (frosted glass, reef/mauve neon,
   *              mono metadata, squircle rounding, animated water caustics).
   * Optional; omit for 'light'. See docs/forking.md.
   */
  design?: 'light' | 'dark'
}

export interface SiteAssets {
  logo: string
  favicon: string
  icon192: string
  icon512: string
  appleTouchIcon: string
  broadcast: string
}

export interface SiteFeatures {
  /** External radio links in the app shells. */
  radio: boolean
  /** Web-push notifications (also gated by VAPID env). */
  push: boolean
  /** Admin broadcast relay (also gated by BROADCAST_WEBHOOK_URL). */
  broadcast: boolean
}

export interface SiteBusiness {
  /** Rental-gear checklist, shared by the profile and register forms. */
  gearItems: string[]
  /** Per-item daily à-la-carte rental price, in the shop currency. */
  gearPrices: Record<string, number>
  /** Fallback full-payment deadline when an event sets none: N days before start. */
  paymentDeadlineFallbackDays: number
  /** Surcharge shown for card / PayPal payment methods, as a whole percent. */
  cardSurchargePercent: number
  /** Flat fee to add a Nitrox course to a dive registration, in shop currency. */
  nitroxCourseFee: number
  /** Case-insensitive regex-alternation fragments that mark a dive as a "trip"
   *  (vs a local shore dive) by title — destination names, "\\bboat\\b", etc.
   *  Empty = never match by title. Used for calendar coloring. */
  tripKeywords: string[]
}

/** The single reference location for the admin weather / BI baseline. */
export interface SiteWeatherRegion {
  latitude: number
  longitude: number
  label: string
}

export interface SiteConfig {
  /** Pairs with CONFIG_CONTRACT_VERSION; bump when this contract changes. */
  configVersion: number
  identity: SiteIdentity
  contact: SiteContact
  urls: SiteUrls
  locale: SiteLocale
  theme: SiteTheme
  assets: SiteAssets
  features: SiteFeatures
  business: SiteBusiness
  weatherRegion: SiteWeatherRegion
}

export const siteConfig: SiteConfig = raw
