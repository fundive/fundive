// ─────────────────────────────────────────────────────────────────────────────
// TEMPLATE for a deployment's fundive.config.ts.
//
// Copy this file to `fundive.config.ts` in your deployment repo and replace every
// value with your own. `defineConfig` gives you full type-checking + autocomplete
// against the platform's config contract.
//
// Infrastructure that does NOT live here (it's per-account, not app data): your
// Supabase + Cloudflare secrets go in .env (see .env.example), and the Worker
// names live in wrangler.toml + workers/push/wrangler.toml.
// See docs/architecture.md.
// ─────────────────────────────────────────────────────────────────────────────

import { defineConfig } from 'fundive/config'

export const siteConfig = defineConfig({
  // Bump only when the platform CHANGELOG says to.
  configVersion: 7,

  identity: {
    // Printed in italics on the registration PDF. Leave blank to omit it.
    // No CJK: the PDF font (jsPDF helvetica) has no CJK glyphs.
    tagline: '',
    appName: 'FunDive',
    shopName: 'Your Dive Shop',
    shortName: 'YourShop',
    description: 'Dive registration and logbook for Your Dive Shop',
    logoAlt: 'Your Dive Shop',
  },

  contact: {
    email: 'hello@example.com',
    phone: '+1 555-000-0000',
    address: '123 Harbour Rd, Your City',
    mapsUrl: 'https://maps.google.com/?q=your+shop',
    lineUrl: 'https://line.me/R/ti/p/%40yourshop',
    whatsappUrl: 'https://wa.me/15550000000',
    paypalLink: 'https://paypal.me/yourshop',
  },

  // No trailing slashes.
  urls: {
    site: 'https://www.example.com',
    app: 'https://app.example.com',
    radio: 'https://radio.example.com',
  },

  locale: {
    timezone: 'Asia/Taipei',
    currency: 'USD',
    currencyLabel: 'USD',
    // The one language the whole app renders in. 'en' | 'zh-TW' | 'ja'.
    language: 'en',
  },

  theme: {
    themeColor: '#0ea5e9',
    backgroundColor: '#0f172a',
    // Visual design: 'light' (default) or 'dark' (dark ocean glass).
    // See docs/forking.md. Omit for 'light'.
    design: 'light',
  },

  // Drop your images into public/ at these paths (or change the paths here).
  assets: {
    logo: '/imgs/fd_logo.png',
    favicon: '/favicon.png',
    icon192: '/icons/icon-192.png',
    icon512: '/icons/icon-512.png',
    appleTouchIcon: '/apple-touch-icon.png',
    broadcast: '/imgs/broadcast.png',
  },

  // Turn off what you don't run.
  features: {
    radio: false,
    push: true,
    broadcast: false,
  },

  business: {
    gearItems: ['BCD', 'Regulator', 'Wetsuit', 'Fins', 'Mask', 'Boots', 'Dive computer'],
    gearPrices: {
      BCD: 15, Regulator: 15, Wetsuit: 10, Fins: 5, Mask: 5, Boots: 3, 'Dive computer': 10,
    },
    paymentDeadlineFallbackDays: 7,
    cardSurchargePercent: 5,
    nitroxCourseFee: 6000,
    // Case-insensitive regex fragments that mark a dive as a "trip" by title
    // (destination names, "\\bboat\\b", …). Empty = never classify by title.
    tripKeywords: ['\\bboat\\b'],
    // Pre-fills the admin boat-manifest export. Leave blank if the shop never
    // charters a boat; notes are printed verbatim, in the shop's own language.
    boatManifest: { boatName: '', registration: '', notes: [] },
  },

  // Home dive region for the admin weather baseline (decimal degrees).
  weatherRegion: { latitude: 0, longitude: 0, label: 'Your home dive region' },
})
