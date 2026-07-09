import { siteConfig } from '../../config/site'
import { t } from '../../i18n'
import type { EventDetails as EventDetailsData } from '../../types/database'

// Text flips with the design variant: dark ink on the light 'light' modal,
// light ink on the dark-glass 'dark' modal.
const DARK = siteConfig.theme.design === 'dark'
const HEADING = DARK ? 'text-white' : 'text-brand-950'
const BODY    = DARK ? 'text-brand-100/85' : 'text-brand-900/90'
const BASE    = DARK ? 'text-brand-100' : 'text-brand-900'

const TEXT_SECTIONS: Array<{ key: keyof EventDetailsData; label: string }> = [
  { key: 'description',    label: t.calendar.eventDetails.description },
  { key: 'included',       label: t.calendar.eventDetails.included },
  { key: 'not_included',   label: t.calendar.eventDetails.notIncluded },
  { key: 'schedule',       label: t.calendar.eventDetails.schedule },
  { key: 'transportation', label: t.calendar.eventDetails.transportation },
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
          <h3 className={`font-semibold ${HEADING}`}>{t.calendar.eventDetails.prerequisites}</h3>
          {details.required_cert && (
            <p className={BODY}>{t.calendar.eventDetails.minCert(details.required_cert)}</p>
          )}
          {details.required_dives != null && (
            <p className={BODY}>{t.calendar.eventDetails.loggedDives(details.required_dives)}</p>
          )}
          {details.prerequisites && (
            <p className={`whitespace-pre-line ${BODY}`}>{details.prerequisites}</p>
          )}
        </section>
      )}
    </div>
  )
}
