import { useState } from 'react'
import { useAuth } from '../hooks/useAuth'
import { Logo } from '../components/Logo'
import { ProfileForm } from './ProfilePage'
import type { Profile } from '../types/database'
import { CARD_ELEVATED, BTN_PRIMARY, TEXT_MUTED } from '../styles/tokens'
import { siteConfig } from '../config/site'
import { t } from '../i18n'

// Holding screen for pending / rejected divers. RequireActive routes
// every non-active diver here; the only way out is admin approval (then
// the next login takes them to /calendar) or signing out.
//
// Three states:
//   - rejected → static "not approved" message + sign out
//   - pending + profile incomplete → ProfileForm so the diver can submit
//     the data the admin needs to approve them
//   - pending + profile complete → waiting-for-approval screen
//
// "Complete" means the seven diver-required fields are populated; an
// admin-set status is the next step.
const REQUIRED: Array<keyof Profile> = [
  'name', 'nickname', 'date_of_birth',
  'contact_method', 'contact_id',
]
function isProfileComplete(p: Profile | null | undefined): boolean {
  if (!p) return false
  const baseFilled = REQUIRED.every(k => {
    const v = p[k]
    return typeof v === 'string' ? v.trim().length > 0 : v != null
  })
  // Certification is satisfied either by an explicit "uncertified" declaration
  // or by a named cert level (uncertified divers legitimately have none).
  const certFilled = p.uncertified === true || (p.cert_level ?? '').trim().length > 0
  return baseFilled && certFilled
}

export function PendingPage() {
  const { user, profile, signOut } = useAuth()
  const rejected = profile?.status === 'rejected'

  // Persistent (profile already complete from a previous session) OR
  // ephemeral (just saved this session) — either flips the diver onto
  // the waiting screen.
  const [savedThisSession, setSavedThisSession] = useState(false)
  const submitted = savedThisSession || isProfileComplete(profile)

  return (
    <div className="min-h-screen bg-brand-900 p-4">
      <div className="w-full max-w-lg mx-auto space-y-4">
        <div className="flex justify-center"><Logo size="lg" /></div>

        {rejected ? (
          <div className={`${CARD_ELEVATED} p-6 text-center`}>
            <h1 className="text-xl font-semibold text-brand-950 mb-2">
              {t.pending.rejectedTitle}
            </h1>
            <p className={`${TEXT_MUTED} text-sm mb-5`}>
              {t.pending.rejectedBodyPrefix}{' '}
              <a href={`mailto:${siteConfig.contact.email}`} className="underline">
                {siteConfig.contact.email}
              </a>{t.pending.rejectedBodySuffix}
            </p>
            <button onClick={signOut} className={`w-full ${BTN_PRIMARY}`}>
              {t.common.signOut}
            </button>
          </div>
        ) : submitted ? (
          <div className={`${CARD_ELEVATED} p-6 text-center`}>
            <h1 className="text-xl font-semibold text-brand-950 mb-2">
              {t.pending.submittedTitle}
            </h1>
            <p className={`${TEXT_MUTED} text-sm mb-5`}>
              {t.pending.submittedBody}
            </p>
            <button onClick={signOut} className={`w-full ${BTN_PRIMARY}`}>
              {t.common.signOut}
            </button>
          </div>
        ) : (
          <>
            <div className={`${CARD_ELEVATED} p-4 text-center`}>
              <h1 className="text-lg font-semibold text-brand-950 mb-1">
                {t.pending.reviewTitle}
              </h1>
              <p className={`${TEXT_MUTED} text-xs`}>
                {t.pending.reviewBody}
              </p>
            </div>

            {user && profile?.id && (
              <ProfileForm
                key={profile.id}
                user={user}
                profile={profile}
                onSaved={() => setSavedThisSession(true)}
              />
            )}

            <button onClick={signOut} className={`w-full ${BTN_PRIMARY}`}>
              {t.common.signOut}
            </button>
          </>
        )}
      </div>
    </div>
  )
}
