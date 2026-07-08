import { useAuth } from '../hooks/useAuth'
import { siteConfig } from '../config/site'
import { Bubbles } from '../components/dashboard/Bubbles'
import { Caustics } from '../components/dashboard/Caustics'
import { FeaturedEvents } from '../components/dashboard/FeaturedEvents'
import { WelcomeBanner } from '../components/welcome/WelcomeBanner'

// Diver + admin landing. The ambient background depends on the design variant:
//   • light — navy container with the rising-bubbles canvas.
//   • dark  — transparent container (the fixed ocean body gradient shows
//     through) with the animated water caustics drifting over it.
// The welcome banner and featured trips sit in a centered column pinned to the
// TOP over either background, so Featured Trips never slip behind the fixed
// bottom nav.
const DARK = siteConfig.theme.design === 'dark'

export function DashboardPage() {
  const { user } = useAuth()

  return (
    <div className={`relative -m-4 -mb-24 min-h-[calc(100vh-3rem)] overflow-hidden ${DARK ? '' : 'bg-brand-900'}`}>
      {DARK ? <Caustics /> : <Bubbles />}
      <div className="relative z-10 mx-auto flex w-full max-w-md flex-col gap-4 px-4 pt-6 pb-28">
        {user && <WelcomeBanner user={user} />}
        <FeaturedEvents />
      </div>

      {/* Powered-by mark — bottom-right, clear of the bottom nav, on one row: the
          light-ink fundive logo (links to the open-source org) beside the version
          chip (links to that release's notes). The dashboard background is navy
          in both themes, so the light-ink logo reads on either. */}
      <div className="fixed bottom-20 right-4 z-40 flex items-center gap-2">
        <a
          href="https://github.com/fundive"
          target="_blank"
          rel="noopener noreferrer"
          aria-label="fundive on GitHub"
          className="opacity-80 transition-opacity hover:opacity-100"
        >
          <img src="/fundive-logo-light.svg" alt="fundive" className="h-14 w-auto drop-shadow-lg" />
        </a>
        <a
          href="https://github.com/fundive/fundive/releases/tag/v0.0.1"
          target="_blank"
          rel="noopener noreferrer"
          aria-label="fundive v0.0.1 release notes"
          className="rounded-full bg-accent px-1.5 py-0.5 text-[9px] font-bold uppercase leading-none tracking-wide text-white shadow transition-colors hover:bg-red-400"
        >
          v0.0.1
        </a>
      </div>
    </div>
  )
}
