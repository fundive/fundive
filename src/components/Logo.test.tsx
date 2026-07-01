import { describe, it, expect } from 'vitest'
import { render, screen } from '@testing-library/react'
import { Logo } from './Logo'
import { siteConfig } from '../config/site'

describe('Logo', () => {
  it('renders the brand image with the height preset for the given size', () => {
    render(<Logo size="sm" />)
    const img = screen.getByAltText(siteConfig.app.logoAlt)
    expect(img).toHaveClass('h-9')
  })

  it('hides the beta badge by default', () => {
    render(<Logo size="sm" />)
    expect(screen.queryByText(/beta/i)).not.toBeInTheDocument()
  })

  it('shows the beta badge when beta is true', () => {
    render(<Logo size="sm" beta />)
    expect(screen.getByText(/beta/i)).toBeInTheDocument()
  })
})
