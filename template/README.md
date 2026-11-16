# My dive shop

This shop's app runs on [FunDive](https://github.com/fundive/fundive). This
repository holds only what makes it ours:

| Path | What |
| --- | --- |
| `fundive.config.ts` | shop name, URLs, locale, design, gear and prices |
| `public/` | our logo, icons and photos, laid over the platform's |
| `wrangler.toml`, `workers/push/wrangler.toml` | our Cloudflare worker names, domain and push settings |
| `.github/workflows/` | manual Deploy and Push-migrations buttons |
| `package.json` | the FunDive version we run |

Setup, deploys and upgrades: https://fundive.github.io/fundive/self-hosting
