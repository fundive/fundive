import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { useState } from 'react'
import { DateField } from './DateField'

// Controlled wrapper mirroring how forms use DateField.
function Harness({ initial = '', onValue }: { initial?: string; onValue?: (v: string) => void }) {
  const [value, setValue] = useState(initial)
  return (
    <DateField
      value={value}
      onChange={v => { setValue(v); onValue?.(v) }}
      aria-label="Date"
    />
  )
}

describe('DateField', () => {
  it('lets the user type a date, auto-masking digits into YYYY-MM-DD', async () => {
    const onValue = vi.fn()
    const user = userEvent.setup()
    render(<Harness onValue={onValue} />)

    const input = screen.getByLabelText('Date')
    await user.type(input, '19870512')

    expect(input).toHaveValue('1987-05-12')
    // Only emits upstream once the typed value is a complete, valid date.
    expect(onValue).toHaveBeenLastCalledWith('1987-05-12')
  })

  it('emits "" while the entry is incomplete', async () => {
    const onValue = vi.fn()
    const user = userEvent.setup()
    render(<Harness onValue={onValue} />)

    await user.type(screen.getByLabelText('Date'), '1987')
    expect(onValue).toHaveBeenLastCalledWith('')
  })

  it('shows the controlled value and offers the calendar affordance', () => {
    render(<DateField value="2001-09-29" onChange={() => {}} aria-label="DOB" />)
    expect(screen.getByLabelText('DOB')).toHaveValue('2001-09-29')
    expect(screen.getByRole('button', { name: /open calendar/i })).toBeInTheDocument()
  })

  it('keeps a half-typed date visible after blur instead of wiping it', async () => {
    const user = userEvent.setup()
    render(<Harness />)

    const input = screen.getByLabelText('Date')
    await user.type(input, '1987')
    await user.tab()

    // An incomplete entry emits '' upstream, but the digits stay on screen —
    // snapping the field back to the controlled '' loses them silently.
    expect(input).toHaveValue('1987')
  })

  it('does not refocus the text input when the calendar is opened from inside a wrapping label', async () => {
    const proto = HTMLInputElement.prototype as unknown as { showPicker?: () => void }
    const origShowPicker = proto.showPicker
    proto.showPicker = vi.fn()
    try {
      const user = userEvent.setup()
      // RegisterForm's TextField wraps the whole control in a <label>. A click
      // bubbling to that label is re-dispatched to the labelled input, which
      // would refocus it and dismiss the picker that just opened.
      render(
        <label>
          <span>DOB</span>
          <DateField value="" onChange={() => {}} aria-label="Date" />
        </label>
      )

      const input = screen.getByLabelText('Date')
      await user.click(screen.getByRole('button', { name: /open calendar/i }))

      expect(document.activeElement).not.toBe(input)
      expect(proto.showPicker).toHaveBeenCalled()
    } finally {
      proto.showPicker = origShowPicker
    }
  })
})
