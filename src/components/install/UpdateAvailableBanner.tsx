// Surfaces "a new version is available — tap to update" when the SW has
// a fresh build waiting. Shows on every platform (Android, iOS, desktop)
// because the update mechanism is the same: post SKIP_WAITING, listen for
// controllerchange, reload. The mobile case is the motivating one — a PWA
// added to the home screen on iOS may stay open across days, so without
// this prompt the user has no visual cue that a deploy has landed.
//
// Single action — Update. There is deliberately no Later/dismiss: an
// out-of-date PWA can hit a backend API the deploy already migrated past,
// so we want the banner to stay loud until the reload happens.

import { pick } from '../../styles/tokens'

import { t } from '../../i18n'

interface Props {
  onUpdate: () => void
}

// An informational "go" action, not a destructive one — so a brand (not red)
// banner with a primary-styled button: the light "light button" look in light,
// the reef accent in dark.
const UPDATE_BTN = pick(
  'bg-white text-brand-800 hover:bg-surface-100',
  'bg-reef-500 text-slate-950 hover:bg-reef-400',
)

export function UpdateAvailableBanner({ onUpdate }: Props) {
  return (
    <div
      role="alert"
      aria-live="polite"
      className="fixed top-0 inset-x-0 z-[110] bg-brand-700 text-white px-4 py-2 flex items-center justify-between gap-3 text-sm shadow-md"
    >
      <span className="font-semibold">{t.install.updateAvailable}</span>
      <button
        type="button"
        onClick={onUpdate}
        className={`${UPDATE_BTN} font-semibold px-3 py-1 rounded-md transition-colors`}
      >
        {t.install.update}
      </button>
    </div>
  )
}
