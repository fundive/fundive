import { useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { supabase } from '../../lib/supabase'
import { EventForm } from '../../components/admin/EventForm'
import { CreateEventVehiclePicker } from '../../components/admin/CreateEventVehiclePicker'
import { assignVehicleToEvent } from '../../lib/event-vehicles'
import { useAuth } from '../../hooks/useAuth'
import { useToast } from '../../hooks/useToast'
import {
  eventPayloadFromForm,
  type FormState,
} from '../../components/admin/event-form-state'
import { saveEventRelations } from '../../lib/event-relations'

// Thin wrapper: defer all field rendering to the shared EventForm and
// handle the create-side persistence (insert a new events row, write its
// room/add-on/destination junctions, then redirect to its admin detail page).
export function AdminNewEventPage() {
  const navigate = useNavigate()
  const toast = useToast()
  const { profile } = useAuth()
  // Cars picked on the create form; assigned to the event row once it exists.
  const [vehicleIds, setVehicleIds] = useState<string[]>([])

  async function handleSubmit(form: FormState) {
    const id = crypto.randomUUID()
    const { error } = await supabase.from('events').insert({ id, ...eventPayloadFromForm(form) } as never)
    if (error) throw error
    const relError = await saveEventRelations(id, form)
    if (relError) throw relError
    // Persist any cars picked on the create form. Allocations are keyed on the
    // dive's start_date — the same day the logistics view groups them under.
    // Non-fatal: the event is already created, so a failed assignment (e.g. a
    // car taken that day) must NOT throw back to the form — that would leave the
    // event orphaned behind an error and invite a duplicate re-submit. Instead
    // warn and still navigate to the event, where cars can be set on the edit page.
    let carWarning = false
    if (form.type === 'dive' && form.start_date && vehicleIds.length > 0 && profile?.id) {
      try {
        for (const vehicleId of vehicleIds) {
          await assignVehicleToEvent({
            vehicleId, date: form.start_date, event: { id, type: 'dive' }, createdBy: profile.id,
          })
        }
      } catch {
        carWarning = true
      }
    }
    toast.success(
      carWarning
        ? 'Dive created — some cars were unavailable; assign them on the edit page.'
        : form.type === 'dive' ? 'Dive created' : 'Course created',
    )
    navigate(`/admin/events/${form.type}/${id}`)
  }

  return (
    <div className="max-w-2xl mx-auto">
      <h1 className="text-2xl font-bold text-white mb-4">New event</h1>
      <EventForm
        mode="create"
        onSubmit={handleSubmit}
        onCancel={() => navigate('/admin/events')}
        renderCreateExtras={(type, { startDate }) => type === 'dive' ? <CreateEventVehiclePicker date={startDate} onChange={setVehicleIds} /> : null}
      />
    </div>
  )
}
