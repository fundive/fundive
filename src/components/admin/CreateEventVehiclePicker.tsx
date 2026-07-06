import { useEffect, useState } from 'react'
import { fetchVehicles } from '../../lib/vehicles'
import { availableVehicles, fetchAssignedVehicleIdsForDate } from '../../lib/event-vehicles'
import type { Vehicle } from '../../types/database'

interface Props {
  /** The new event's date — cars already taken that day are hidden. */
  date: string | null
  /** Reports the picked vehicle ids up so the create page can assign them to
   *  the new event once its row exists. */
  onChange: (vehicleIds: string[]) => void
}

/**
 * Car assignment for the New-event form. The event row doesn't exist yet, so
 * this holds the picked vehicles in local state and hands the ids up; the page
 * persists them (event_vehicles) right after inserting the event. Cars already
 * allocated to another event on the same date are hidden (a car is exclusive per
 * date). Edit uses the DB-backed EventCarAssignment instead.
 */
export function CreateEventVehiclePicker({ date, onChange }: Props) {
  const [vehicles, setVehicles] = useState<Vehicle[]>([])
  const [takenIds, setTakenIds] = useState<Set<string>>(new Set())
  const [selected, setSelected] = useState<Set<string>>(new Set())
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    let cancelled = false
    ;(async () => {
      try {
        const [v, taken] = await Promise.all([
          fetchVehicles(),
          date ? fetchAssignedVehicleIdsForDate(date) : Promise.resolve(new Set<string>()),
        ])
        if (!cancelled) { setVehicles(v.filter(x => x.active)); setTakenIds(taken) }
      } catch { /* no fleet / offline — section stays empty */ }
      finally { if (!cancelled) setLoading(false) }
    })()
    return () => { cancelled = true }
  }, [date])

  const available = availableVehicles(vehicles, takenIds)

  // Report the AVAILABLE subset of the selection up, in an effect (not inside
  // the state updater) so it re-syncs cleanly on remount (dive→course→dive) and
  // after a date change. Picks that are no longer available just aren't reported
  // (and don't render), so nothing invisible gets assigned.
  useEffect(() => {
    const availableIds = new Set(available.map(v => v.id))
    onChange([...selected].filter(id => availableIds.has(id)))
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [selected, vehicles, takenIds])

  function toggle(id: string) {
    setSelected(prev => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id); else next.add(id)
      return next
    })
  }

  const seats = available.filter(v => selected.has(v.id)).reduce((s, v) => s + v.passenger_seats, 0)

  return (
    <div className="space-y-2">
      <div className="flex items-baseline justify-between gap-3">
        <h2 className="text-sm font-bold text-white uppercase tracking-wider">Cars for this dive</h2>
        {selected.size > 0 && (
          <span className="text-xs text-white/70 font-semibold">{seats} passenger seat{seats === 1 ? '' : 's'}</span>
        )}
      </div>
      <p className="text-xs text-white/60">
        Cars assigned here set the ride-seat limit on the registration form — a diver can only
        request a ride when a seat is free in one of them. You can change these later.
      </p>
      {loading ? (
        <p className="text-sm text-white/60">Loading cars…</p>
      ) : available.length === 0 ? (
        <p className="text-sm text-brand-950 font-medium bg-white/70 rounded-md p-2">
          {vehicles.length === 0 ? 'No active cars in the fleet.' : 'No cars free on this date.'}
        </p>
      ) : (
        <div className="space-y-1 max-h-56 overflow-y-auto bg-white/70 backdrop-blur-md border border-surface-200 rounded-md p-2">
          {available.map(v => (
            <label key={v.id} className="flex items-center gap-2 text-sm text-brand-950 font-medium">
              <input
                type="checkbox"
                checked={selected.has(v.id)}
                onChange={() => toggle(v.id)}
                className="accent-brand-900"
              />
              <span>{v.name} ({v.passenger_seats} seat{v.passenger_seats === 1 ? '' : 's'})</span>
            </label>
          ))}
        </div>
      )}
    </div>
  )
}
