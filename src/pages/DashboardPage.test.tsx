import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import { siteConfig } from '../config/site'
import { MemoryRouter } from 'react-router-dom'
import { DashboardPage } from './DashboardPage'

const { useAuthMock } = vi.hoisted(() => ({ useAuthMock: vi.fn() }))
vi.mock('../hooks/useAuth', () => ({ useAuth: () => useAuthMock() }))
// FeaturedEvents fetches on mount; it has its own test. Stub it here so these
// tests stay focused on the bubble overlay and welcome banner.
vi.mock('../components/dashboard/FeaturedEvents', () => ({
  FeaturedEvents: () => null,
}))

// happy-dom provides a Canvas stub but getContext returns null by default.
// We replace it with a minimal 2d-context stand-in so the effect can complete
// without throwing. The actual rAF loop is not inspected.
beforeEach(() => {
  vi.stubGlobal('ResizeObserver', class {
    observe() {}
    disconnect() {}
    unobserve() {}
  })
  HTMLCanvasElement.prototype.getContext = vi.fn(() => ({
    setTransform: vi.fn(),
    fillRect:     vi.fn(),
    beginPath:    vi.fn(),
    arc:          vi.fn(),
    fill:         vi.fn(),
    scale:        vi.fn(),
    fillStyle:    '',
  })) as unknown as HTMLCanvasElement['getContext']
  useAuthMock.mockReset()
})

function renderPage() {
  return render(<MemoryRouter><DashboardPage /></MemoryRouter>)
}

describe('DashboardPage', () => {
  it('renders the bubbles canvas', () => {
    useAuthMock.mockReturnValue({ user: null, profile: null })
    renderPage()
    expect(document.querySelector('canvas')).not.toBeNull()
  })

  it('shows the WelcomeBanner for a user welcomed within the last 24h', () => {
    useAuthMock.mockReturnValue({
      user: { user_metadata: { welcomed_at: new Date().toISOString() } },
      profile: null,
    })
    renderPage()
    expect(screen.getByText(new RegExp(`welcome to ${siteConfig.identity.shortName}`, 'i'))).toBeInTheDocument()
  })

  it('hides the WelcomeBanner once 24h have passed since welcomed_at', () => {
    const longAgo = new Date(Date.now() - 25 * 60 * 60 * 1000).toISOString()
    useAuthMock.mockReturnValue({
      user: { user_metadata: { welcomed_at: longAgo } },
      profile: null,
    })
    renderPage()
    expect(screen.queryByText(/welcome to fundivers/i)).not.toBeInTheDocument()
  })

  it('hides the WelcomeBanner for a user who has never been welcomed', () => {
    useAuthMock.mockReturnValue({
      user: { user_metadata: {} },
      profile: null,
    })
    renderPage()
    expect(screen.queryByText(/welcome to fundivers/i)).not.toBeInTheDocument()
  })

  it('renders the quick links when asked, below the featured trips', () => {
    useAuthMock.mockReturnValue({ user: { user_metadata: {} }, profile: null })
    render(<MemoryRouter><DashboardPage quickLinks /></MemoryRouter>)
    expect(screen.getByRole('link', { name: /trusted partners/i })).toBeInTheDocument()
    expect(screen.getByText(/dive site maps/i)).toBeInTheDocument()
  })

  // The tile was admin-and-dev-server-only while the map had nowhere to store
  // anything. It reads and collects real observations now, so it is open to
  // whoever can dive — which is the whole point of crowdsourcing a seabed.
  it('opens the dive-site maps to every signed-in diver, whatever their role', () => {
    for (const role of ['diver', 'staff', 'admin']) {
      useAuthMock.mockReturnValue({ user: { user_metadata: {} }, profile: { role } })
      const { unmount } = render(<MemoryRouter><DashboardPage quickLinks /></MemoryRouter>)
      expect(screen.getByRole('link', { name: /dive site maps/i })).toHaveAttribute('href', '/site-maps')
      unmount()
    }
  })

  it('omits them unless asked, so an embedder without room for them can opt out', () => {
    useAuthMock.mockReturnValue({ user: { user_metadata: {} }, profile: null })
    renderPage()
    expect(screen.queryByRole('link', { name: /trusted partners/i })).not.toBeInTheDocument()
  })
})
