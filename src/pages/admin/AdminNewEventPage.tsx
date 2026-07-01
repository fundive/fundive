import { useNavigate } from 'react-router-dom'
import { supabase } from '../../lib/supabase'
import { EventForm } from '../../components/admin/EventForm'
import { useToast } from '../../hooks/useToast'
import {
  divePayloadFromForm,
  coursePayloadFromForm,
  type FormState,
} from '../../components/admin/event-form-state'
import { saveEventRelations } from '../../lib/event-relations'

// Thin wrapper: defer all field rendering to the shared EventForm and
// handle the create-side persistence (insert a new EO_dive / EO_course
// row, write its room/add-on/destination junctions, then redirect to its
// admin detail page).
export function AdminNewEventPage() {
  const navigate = useNavigate()
  const toast = useToast()

  async function handleSubmit(form: FormState) {
    const id = crypto.randomUUID()
    const table = form.type === 'dive' ? 'EO_dives' : 'EO_courses'
    const payload = form.type === 'dive' ? divePayloadFromForm(form) : coursePayloadFromForm(form)
    const { error } = await supabase.from(table).insert({ _id: id, ...payload } as never)
    if (error) throw error
    const relError = await saveEventRelations(form.type, id, form)
    if (relError) throw relError
    toast.success(form.type === 'dive' ? 'Dive created' : 'Course created')
    navigate(`/admin/events/${form.type}/${id}`)
  }

  return (
    <div className="max-w-2xl mx-auto">
      <h1 className="text-2xl font-bold text-white mb-4">New event</h1>
      <EventForm
        mode="create"
        onSubmit={handleSubmit}
        onCancel={() => navigate('/admin/events')}
      />
    </div>
  )
}
