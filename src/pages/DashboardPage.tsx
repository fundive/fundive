import { useAuth } from '../hooks/useAuth'
import { siteConfig } from '../config/site'
import { Bubbles } from '../components/dashboard/Bubbles'
import { Caustics } from '../components/dashboard/Caustics'
import { FeaturedEvents } from '../components/dashboard/FeaturedEvents'
import { WelcomeBanner } from '../components/welcome/WelcomeBanner'

// Diver + admin landing. The ambient background depends on the design variant:
//   • family — navy container with the rising-bubbles canvas.
//   • riced  — transparent container (the fixed ocean body gradient shows
//     through) with the animated water caustics drifting over it.
// The welcome banner and featured trips sit in a centered column pinned to the
// TOP over either background, so Featured Trips never slip behind the fixed
// bottom nav.
const RICED = siteConfig.theme.design === 'riced'

export function DashboardPage() {
  const { user } = useAuth()

  return (
    <div className={`relative -m-4 -mb-24 min-h-[calc(100vh-3rem)] overflow-hidden ${RICED ? '' : 'bg-brand-900'}`}>
      {RICED ? <Caustics /> : <Bubbles />}
      <div className="relative z-10 mx-auto flex w-full max-w-md flex-col gap-4 px-4 pt-6 pb-28">
        {user && <WelcomeBanner user={user} />}
        <FeaturedEvents />
      </div>
    </div>
  )
}
