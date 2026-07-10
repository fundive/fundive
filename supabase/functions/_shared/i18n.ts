// The shop's message catalog, for the Deno edge-function runtime.
//
// This mirrors src/i18n/index.ts but cannot reuse it: that module imports
// src/config/site.ts, which resolves the `virtual:fundive-config` Vite
// specifier — which only exists inside the Vite module graph, not in Deno. The
// catalogs themselves are pure data with no config or React imports, precisely
// so they stay importable from here.
//
// The language comes from `./config.ts`, NOT from the platform's own
// fundive.config.ts: a deployment's resolved config is injected as the
// FUNDIVE_CONFIG secret at deploy time, so emails render in that deployment's
// shop-facing language rather than the platform default.
//
// Shop-authored content (waiver bodies, boat-manifest notes) is never
// translated and never lives in a catalog.

import { siteConfig } from "./config.ts"
import { en, type Messages } from "../../../src/i18n/messages/en.ts"
import { zhTW } from "../../../src/i18n/messages/zh-TW.ts"
import { ja } from "../../../src/i18n/messages/ja.ts"

export type { Messages }

const catalogs: Record<string, Messages> = {
  en,
  "zh-TW": zhTW,
  ja,
}

export const t: Messages = catalogs[siteConfig.locale.language]
