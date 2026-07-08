import { siteConfig } from '../../config/site'
import type { EventDetails as EventDetailsData } from '../../types/database'

// Text flips with the design variant: dark ink on the light 'light' modal,
// light ink on the dark-glass 'dark' modal.
const DARK = siteConfig.theme.design === 'dark'
const HEADING = DARK ? 'text-white' : 'text-brand-950'
const BODY    = DARK ? 'text-brand-100/85' : 'text-brand-900/90'
const BASE    = DARK ? 'text-brand-100' : 'text-brand-900'

const TEXT_SECTIONS: Array<{ key: keyof EventDetailsData; label: string }> = [
  { key: 'description',    label: 'About this event' },
  { key: 'included',       label: "What's included" },
  { key: 'not_included',   label: 'Not included' },
  { key: 'schedule',       label: 'Schedule / itinerary' },
  { key: 'transportation', label: 'Transportation' },
]

/**
 * Diver-facing detail block shown inside the calendar event modal. Renders
 * only the sections an event actually has; the prerequisites block folds the
 * required cert level, minimum logged dives, and free-text prereqs together.
 */
export function EventDetails({ details }: { details: EventDetailsData }) {
  const hasPrereqs =
    Boolean(details.required_cert) ||
    details.required_dives != null ||
    Boolean(details.prerequisites)

  return (
    <div className={`space-y-3 text-sm ${BASE} max-h-80 overflow-y-auto pr-1`}>
      {TEXT_SECTIONS.map(({ key, label }) => {
        const value = details[key] as string | null
        if (!value) return null
        return (
          <section key={key}>
            <h3 className={`font-semibold ${HEADING}`}>{label}</h3>
            <p className={`whitespace-pre-line ${BODY}`}>{value}</p>
          </section>
        )
      })}

      {hasPrereqs && (
        <section>
          <h3 className={`font-semibold ${HEADING}`}>Prerequisites</h3>
          {details.required_cert && (
            <p className={BODY}>Minimum certification: {details.required_cert}</p>
          )}
          {details.required_dives != null && (
            <p className={BODY}>Logged dives: {details.required_dives}+</p>
          )}
          {details.prerequisites && (
            <p className={`whitespace-pre-line ${BODY}`}>{details.prerequisites}</p>
          )}
        </section>
      )}
    </div>
  )
}
