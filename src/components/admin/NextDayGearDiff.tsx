import type { GearDayDiff, GearDiffLine } from '../../lib/logistics'
import { TEXT_MUTED, TEXT_SUBTLE, TEXT_SUCCESS, TEXT_WARNING, pick } from '../../styles/tokens'
import { t } from '../../i18n'

const lg = t.admin.logistics

// The three columns sit on the Overall board, so each tone has to read against
// whichever surface that board is in the active design. Stays-out is emerald
// because it is the one column with no work in it; also-pack takes the design's
// "act here" accent; back-to-the-shop is deliberately the dimmest, since it's a
// note rather than a task.
const COLUMN_TONES = {
  keep: {
    label: TEXT_SUCCESS,
    chip: pick('border-emerald-400 bg-emerald-50 text-emerald-900', 'border-emerald-400/40 bg-emerald-500/10 text-emerald-50'),
  },
  add: {
    label: pick('text-brand-800', 'text-reef-300'),
    chip: pick('border-brand-900/40 bg-brand-900/5 text-brand-900', 'border-reef-400/45 bg-reef-400/10 text-reef-50'),
  },
  free: {
    label: TEXT_MUTED,
    chip: pick('border-brand-900/20 bg-brand-900/5 text-brand-900/80', 'border-white/15 bg-white/5 text-brand-100/80'),
  },
} as const

const CHASE_PANEL = pick('border-amber-400 bg-amber-50', 'border-amber-500/40 bg-amber-500/10')
const CHASE_TEXT = pick('text-amber-900', 'text-amber-100')

/** "BCD ×2", or "BCD · M ×2" once the shop packs the item in sizes. */
function pieceLabel(line: GearDiffLine, n: number): string {
  return line.size ? lg.gearPieceSized(line.item, line.size, n) : lg.gearPiece(line.item, n)
}

function DiffColumn({ title, hint, tone, lines, count }: {
  title: string
  hint: string
  tone: keyof typeof COLUMN_TONES
  lines: Array<{ line: GearDiffLine; n: number }>
  count: number
}) {
  const { label, chip } = COLUMN_TONES[tone]
  return (
    <div role="group" aria-label={title} className="space-y-1.5">
      <div>
        <h4 className={`text-[11px] font-semibold uppercase tracking-wider ${label}`}>
          {title} · {lg.nextDayPieces(count)}
        </h4>
        <p className={`text-[11px] ${TEXT_SUBTLE}`}>{hint}</p>
      </div>
      {lines.length === 0 ? (
        <p className={`text-xs italic ${TEXT_SUBTLE}`}>{lg.nextDayNone}</p>
      ) : (
        <ul className="flex flex-wrap gap-1.5">
          {lines.map(({ line, n }) => (
            <li
              key={`${line.item}|${line.size ?? ''}`}
              className={`text-xs px-2 py-0.5 rounded-full border font-medium ${chip}`}
            >
              {pieceLabel(line, n)}
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}

/**
 * The overlap between the day on screen and the next one, for a shop running
 * back-to-back days: what already on the van gets reused, what still has to
 * come off the rack, and what goes home to dry. Matched size by size, because
 * that's the unit a piece is actually reusable at.
 *
 * `diff` is null while the next day is still loading; `failed` when the read
 * errored, which must be said out loud — an empty next day and an unreadable
 * one produce very different packing advice from identical-looking panels.
 */
export function NextDayGearDiff({ day, diff, failed = false }: {
  day: string
  diff: GearDayDiff | null
  failed?: boolean
}) {
  // Unsized pieces are held out of the three columns entirely. They can't be
  // matched, so they'd otherwise appear in "also pack" AND "back to the shop"
  // at once, crowding out the real answer — and one unsized diver puts a line
  // in all four sized items, which reads as "the diff can't see any sizes".
  const sizedLines = (diff?.lines ?? []).filter(l => !l.unknownSize)
  const unsized = (diff?.lines ?? []).filter(l => l.unknownSize)
  return (
    <div className={`space-y-2 rounded-lg border p-3 ${pick('border-surface-300 bg-surface-50', 'border-white/15 bg-white/5')}`}>
      <div>
        <h3 className={`text-[11px] font-semibold uppercase tracking-wider ${TEXT_MUTED}`}>
          {lg.nextDayHeading(day)}
        </h3>
        <p className={`text-xs ${TEXT_MUTED}`}>{lg.nextDayHint}</p>
      </div>
      {failed ? (
        <p className={`text-sm font-semibold ${TEXT_WARNING}`}>{lg.nextDayFailed}</p>
      ) : diff === null ? (
        <p className={`text-sm italic ${TEXT_MUTED}`}>{lg.nextDayLoading}</p>
      ) : diff.lines.length === 0 ? (
        <p className={`text-sm italic ${TEXT_MUTED}`}>{lg.nextDayNothing}</p>
      ) : (
        <>
          <div className="grid gap-x-5 gap-y-4 sm:grid-cols-3 items-start">
            <DiffColumn
              title={lg.nextDayStaysOut} hint={lg.nextDayStaysOutHint} tone="keep" count={diff.keep}
              lines={sizedLines.filter(l => l.keep > 0).map(line => ({ line, n: line.keep }))}
            />
            <DiffColumn
              title={lg.nextDayAlsoPack} hint={lg.nextDayAlsoPackHint} tone="add" count={diff.add}
              lines={sizedLines.filter(l => l.add > 0).map(line => ({ line, n: line.add }))}
            />
            <DiffColumn
              title={lg.nextDayBackToShop} hint={lg.nextDayBackToShopHint} tone="free" count={diff.free}
              lines={sizedLines.filter(l => l.free > 0).map(line => ({ line, n: line.free }))}
            />
          </div>
          {unsized.length > 0 && (
            <div role="group" aria-label={lg.nextDayChase} className={`rounded-lg border p-2 space-y-1 ${CHASE_PANEL}`}>
              <div>
                <h4 className={`text-[11px] font-semibold uppercase tracking-wider ${TEXT_WARNING}`}>
                  {lg.nextDayChase} · {lg.nextDayPieces(diff.unsized)}
                </h4>
                <p className={`text-[11px] ${CHASE_TEXT}`}>{lg.nextDayChaseHint}</p>
              </div>
              <ul className="space-y-0.5">
                {unsized.map(l => (
                  <li key={`chase-${l.item}`} className={`text-xs ${CHASE_TEXT}`}>
                    <span className="font-semibold">{lg.gearPiece(l.item, Math.max(l.today, l.next))}</span>
                    {l.nextDivers.length > 0 && (
                      <>{' · '}<span className="select-text">{l.nextDivers.join(', ')}</span></>
                    )}
                  </li>
                ))}
              </ul>
            </div>
          )}
        </>
      )}
    </div>
  )
}
