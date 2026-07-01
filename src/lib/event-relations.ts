import { supabase } from './supabase'
import type { EventRelations, EventType } from '../components/admin/event-form-state'

// An event's related catalog ids live in the junction tables (eo_dive_rooms,
// eo_dive_addons / eo_course_addons, eo_dive_destinations) — the single source
// of truth. These helpers load them for editing/preload and write them back
// transactionally via the set_event_relations RPC.

const EMPTY: EventRelations = { roomIds: [], addonIds: [], destinationIds: [] }

/** Load an event's room / add-on / destination ids from the junction tables. */
export async function fetchEventRelations(type: EventType, id: string): Promise<EventRelations> {
  if (type === 'course') {
    const { data } = await supabase
      .from('eo_course_addons').select('addon_id').eq('eo_course_id', id)
    return { ...EMPTY, addonIds: (data ?? []).map(r => r.addon_id) }
  }
  const [rooms, addons, dests] = await Promise.all([
    supabase.from('eo_dive_rooms').select('room_id').eq('eo_dive_id', id),
    supabase.from('eo_dive_addons').select('addon_id').eq('eo_dive_id', id),
    supabase.from('eo_dive_destinations').select('destination_id').eq('eo_dive_id', id),
  ])
  return {
    roomIds: (rooms.data ?? []).map(r => r.room_id),
    addonIds: (addons.data ?? []).map(r => r.addon_id),
    destinationIds: (dests.data ?? []).map(r => r.destination_id),
  }
}

/**
 * Reconcile an event's junction rows to `rels` in one transaction. Call after the
 * EO_dives/EO_courses row insert/update succeeds. Returns the RPC error (if any)
 * so callers surface it the same way as the row write.
 */
export async function saveEventRelations(type: EventType, id: string, rels: EventRelations) {
  const { error } = await supabase.rpc('set_event_relations', {
    p_event_type: type,
    p_event_id: id,
    p_room_ids: rels.roomIds,
    p_addon_ids: rels.addonIds,
    p_destination_ids: rels.destinationIds,
  })
  return error
}
