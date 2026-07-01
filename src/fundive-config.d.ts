// The deployment's config, injected by the `fundive` Vite plugin (src/vite).
// Resolved to the fundive.config.ts in the cwd where the build/test runs.
// Inline `import()` type (no top-level import) keeps this a global ambient
// declaration rather than a module augmentation.
declare module 'virtual:fundive-config' {
  export const siteConfig: import('./config/site').SiteConfig
}
