import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor, fireEvent } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { AdminEditEventPage } from './AdminEditEventPage'
import { mockQueryBuilder } from '../../../tests/test-utils'

const { from, rpc, moveSpy } = vi.hoisted(() => ({ from: vi.fn(), rpc: vi.fn(), moveSpy: vi.fn() }))
vi.mock('../../lib/supabase', () => ({
  supabase: { from: (...a: unknown[]) => from(...a), rpc: (...a: unknown[]) => rpc(...a) },
}))
vi.mock('../../hooks/useAuth', () => ({
  useAuth: () => ({ profile: { id: 'admin-1', role: 'admin' } }),
}))
vi.mock('../../lib/event-vehicles', async () => {
  const actual = await vi.importActual<typeof import('../../lib/event-vehicles')>('../../lib/event-vehicles')
  return { ...actual, moveDiveCarAllocations: (...a: unknown[]) => moveSpy(...a) }
})

beforeEach(() => {
  from.mockReset()
  rpc.mockReset()
  // set_event_relations reconciles the junctions after the row update.
  rpc.mockResolvedValue({ error: null })
  moveSpy.mockReset()
  moveSpy.mockResolvedValue({ moved: 0, dropped: 0 })
})

function renderAt(path: string) {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <Routes>
        <Route path="/admin/events/:type/:id/edit" element={<AdminEditEventPage />} />
        <Route path="/admin/events/:type/:id"      element={<div>EVENT_DETAIL</div>} />
      </Routes>
    </MemoryRouter>
  )
}

describe('AdminEditEventPage', () => {
  it('prefills the form from the events row and submits an update on save', async () => {
    const existing = {
      id: 'dive_x', kind: 'dive',
      admin_title: 'Kenting Day Trip',
      display_title: 'Subtitle',
      start_date: '2026-06-01',
      start_time: '08:00:00',
      end_date: '2026-06-01',
      featured: false,
      fully_booked: false,
      price: null,
      gear_rental: null,
      nitrox_required: false,
      dive_days: 1,
      featured_image: null,
      second_image: null,
      prereqs: null,
      req_dives: null,
      notes: 'Bring fins',
      cancel_date: null,
      cancel_policy: null,
      trip_template_id: null,
      prereq_cert_id: null,
      cancelled_at: null,
    }

    const updateSpy = vi.fn().mockReturnValue({
      eq: () => Promise.resolve({ error: null }),
    })
    from.mockImplementation((table: string) => {
      if (table === 'events') {
        // The page calls .select('*').eq('id', id).maybeSingle()
        // and then .update(payload).eq('id', id) on submit.
        // Hand both code paths the right surface from one builder.
        const b = mockQueryBuilder({ data: existing }) as Record<string, unknown>
        b.update = updateSpy
        return b
      }
      // Catalog reads (prices/rooms/addons/cert_levels) just return empty.
      return mockQueryBuilder({ data: [] })
    })

    const user = userEvent.setup()
    renderAt('/admin/events/dive/dive_x/edit')

    // Form prefills the existing dive title.
    const titleInput = await screen.findByLabelText(/admin title \(required, internal\)/i) as HTMLInputElement
    await waitFor(() => expect(titleInput.value).toBe('Kenting Day Trip'))
    expect((screen.getByLabelText(/start date/i) as HTMLInputElement).value).toBe('2026-06-01')
    expect((screen.getByLabelText(/notes/i) as HTMLTextAreaElement).value).toBe('Bring fins')

    // Type a new title and save.
    await user.clear(titleInput)
    await user.type(titleInput, 'Kenting Day Trip (revised)')
    await user.click(screen.getByRole('button', { name: /save changes/i }))

    await waitFor(() => expect(updateSpy).toHaveBeenCalled())
    const payload = (updateSpy.mock.calls[0]?.[0] ?? {}) as Record<string, unknown>
    expect(payload.admin_title).toBe('Kenting Day Trip (revised)')
    // Update payload should not carry id (that's in the .eq filter).
    expect(payload.id).toBeUndefined()
    // Navigated to the detail page after save.
    expect(await screen.findByText('EVENT_DETAIL')).toBeInTheDocument()
  })

  it('shows the car-assignment section and moves allocations when the start date changes on save', async () => {
    const existing = {
      id: 'dive_x', kind: 'dive', admin_title: 'Kenting Day Trip', display_title: 'Subtitle',
      start_date: '2026-06-01', start_time: '08:00:00', end_date: '2026-06-01',
      featured: false, fully_booked: false, price: null,
      gear_rental: null, nitrox_required: false, dive_days: 1,
      featured_image: null, second_image: null, prereqs: null, req_dives: null,
      notes: '', cancel_date: null, cancel_policy: null,
      trip_template_id: null,
      prereq_cert_id: null, cancelled_at: null,
    }
    const updateSpy = vi.fn().mockReturnValue({ eq: () => Promise.resolve({ error: null }) })
    from.mockImplementation((table: string) => {
      if (table === 'events') {
        const b = mockQueryBuilder({ data: existing }) as Record<string, unknown>
        b.update = updateSpy
        return b
      }
      return mockQueryBuilder({ data: [] })
    })

    const user = userEvent.setup()
    renderAt('/admin/events/dive/dive_x/edit')
    await screen.findByLabelText(/admin title \(required, internal\)/i)

    // The edit form now carries a "Cars for this dive" section.
    expect(screen.getByText(/cars for this dive/i)).toBeInTheDocument()
    // ...and a per-event "Waiver requirements" section.
    expect(await screen.findByText(/waiver requirements/i)).toBeInTheDocument()

    // Move the dive a week later, then save.
    fireEvent.change(screen.getByLabelText(/start date/i), { target: { value: '2026-06-08' } })
    await user.click(screen.getByRole('button', { name: /save changes/i }))

    await waitFor(() => expect(moveSpy).toHaveBeenCalledWith('dive_x', '2026-06-01', '2026-06-08'))
  })

  it('prefills the featured/second image URL fields and round-trips them into the update payload', async () => {
    // Both inputs round-trip the image URL verbatim — no parsing/validation.
    const existing = {
      id: 'dive_x', kind: 'dive',
      admin_title: 'Kenting Day Trip',
      display_title: 'Subtitle',
      start_date: '2026-06-01',
      start_time: '08:00:00',
      end_date: '2026-06-01',
      featured: false,
      fully_booked: false,
      price: null,
      gear_rental: null,
      nitrox_required: false,
      dive_days: 1,
      featured_image: 'https://cdn.example/featured.jpg',
      second_image:   'https://cdn.example/second.jpg',
      prereqs: null, req_dives: null,
      notes: '',
      cancel_date: null, cancel_policy: null,
      trip_template_id: null,
      prereq_cert_id: null, cancelled_at: null,
    }
    const updateSpy = vi.fn().mockReturnValue({ eq: () => Promise.resolve({ error: null }) })
    from.mockImplementation((table: string) => {
      if (table === 'events') {
        const b = mockQueryBuilder({ data: existing }) as Record<string, unknown>
        b.update = updateSpy
        return b
      }
      return mockQueryBuilder({ data: [] })
    })

    const user = userEvent.setup()
    renderAt('/admin/events/dive/dive_x/edit')

    const featuredInput = await screen.findByLabelText(/featured image url/i) as HTMLInputElement
    const secondInput = screen.getByLabelText(/second image url/i) as HTMLInputElement
    await waitFor(() => {
      expect(featuredInput.value).toBe(existing.featured_image)
      expect(secondInput.value).toBe(existing.second_image)
    })

    // Swap both for new URLs and save.
    await user.clear(featuredInput)
    await user.type(featuredInput, 'https://cdn.example/new-hero.jpg')
    await user.clear(secondInput)
    await user.click(screen.getByRole('button', { name: /save changes/i }))

    await waitFor(() => expect(updateSpy).toHaveBeenCalled())
    const payload = (updateSpy.mock.calls[0]?.[0] ?? {}) as Record<string, unknown>
    expect(payload.featured_image).toBe('https://cdn.example/new-hero.jpg')
    // Empty input round-trips to null in the payload.
    expect(payload.second_image).toBeNull()
  })

  it('renders an error and no form when the dive is not found', async () => {
    from.mockImplementation((table: string) => {
      if (table === 'events') return mockQueryBuilder({ data: null })
      return mockQueryBuilder({ data: [] })
    })

    renderAt('/admin/events/dive/missing/edit')
    expect(await screen.findByText(/event not found/i)).toBeInTheDocument()
    expect(screen.queryByLabelText(/admin title \(required, internal\)/i)).not.toBeInTheDocument()
  })
})
