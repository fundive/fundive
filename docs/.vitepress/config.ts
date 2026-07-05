import { defineConfig } from 'vitepress'

// Docs site for FunDive, built from the markdown in docs/ and published to
// GitHub Pages at https://fundive.github.io/fundive/ (hence base '/fundive/').
export default defineConfig({
  title: 'FunDive',
  description: 'Free, open-source, self-hostable software for running a scuba dive center.',
  base: '/fundive/',
  lastUpdated: true,
  cleanUrls: true,
  // The docs link to repo-root files (README, source, config, Makefile,
  // wrangler.toml, .env.example) that live outside the docs site. Those resolve
  // fine when browsing the repo on GitHub but aren't pages here, so don't fail
  // the build on them. Internal cross-links are still checked.
  ignoreDeadLinks: [/\.\.\//],
  themeConfig: {
    nav: [
      { text: 'Self-hosting', link: '/self-hosting' },
      { text: 'Forking', link: '/forking' },
      { text: 'Deployment', link: '/deployment' },
    ],
    search: { provider: 'local' },
    sidebar: [
      {
        text: 'Get started',
        items: [
          { text: 'Overview', link: '/' },
          { text: 'Self-hosting walkthrough', link: '/self-hosting' },
          { text: 'Forking for your shop', link: '/forking' },
          { text: 'Deployment', link: '/deployment' },
        ],
      },
      {
        text: 'Platform',
        items: [
          { text: 'Architecture', link: '/architecture' },
          { text: 'Data model', link: '/data-model' },
          { text: 'Authentication', link: '/authentication' },
        ],
      },
      {
        text: 'Features',
        items: [
          { text: 'Events & bookings', link: '/events-and-bookings' },
          { text: 'Payments', link: '/payments' },
          { text: 'Admin', link: '/admin' },
          { text: 'Trip board', link: '/trip-board' },
          { text: 'Push notifications', link: '/push-notifications' },
        ],
      },
      {
        text: 'Contributing',
        items: [{ text: 'Testing', link: '/testing' }],
      },
    ],
    socialLinks: [{ icon: 'github', link: 'https://github.com/fundive/fundive' }],
    editLink: {
      pattern: 'https://github.com/fundive/fundive/edit/main/docs/:path',
      text: 'Edit this page on GitHub',
    },
    footer: {
      message: 'Released under the AGPL-3.0-or-later license.',
      copyright: 'Copyright © 2026 FunDive contributors',
    },
  },
})
