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
// The welcome banner and featured trips float above either background.
const RICED = siteConfig.theme.design === 'riced'

export function DashboardPage() {
  const { user } = useAuth()

  return (
    <div className={`relative -m-4 -mb-24 h-[calc(100vh-3rem)] overflow-hidden ${RICED ? '' : 'bg-brand-900'}`}>
      {RICED ? <Caustics /> : <Bubbles />}
      {user && (
        <div className="absolute top-4 right-4 left-auto max-w-sm z-10">
          <WelcomeBanner user={user} />
        </div>
      )}
      <FeaturedEvents />
    </div>
  )
}
