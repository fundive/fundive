import type { AnnualWaiverStatus } from '../../lib/waivers'
import { TEXT_DANGER, TEXT_WARNING, TEXT_SUCCESS, pick } from '../../styles/tokens'
import { t } from '../../i18n'

// How an annual waiver's state reads, shared by the diver's own My Waivers
// panel and the admin's DiverWaivers panel. Both show the same fact about the
// same row, so they must not drift into describing it differently — the copy is
// role-neutral for exactly that reason.
//
// The light design goes through the theme tokens because the raw status shades
// (text-red-600, text-amber-700) fall under 3:1 on its white cards. The dark
// design keeps those raw shades, which clear 3:1 on its glass and are what the
// FunDivers deployment has always shown. The contrast sweep cannot see a
// module-scope map like this one, so getting it wrong here would ship unnoticed.

type State = AnnualWaiverStatus['state']

export const ANNUAL_STATUS_LABEL: Record<State, string> = {
  signed: t.profile.waivers.statusSigned,
  expired: t.profile.waivers.statusExpired,
  outdated: t.profile.waivers.statusOutdated,
  unsigned: t.profile.waivers.statusUnsigned,
}

export const ANNUAL_STATUS_CLASS: Record<State, string> = {
  signed: pick(TEXT_SUCCESS, 'text-emerald-700'),
  expired: pick(TEXT_DANGER, 'text-red-600'),
  outdated: pick(TEXT_WARNING, 'text-amber-700'),
  unsigned: pick(TEXT_DANGER, 'text-red-600'),
}
