import { siteConfig } from '../config/site'

// Share-link target for an event. By default the app's own registration page:
// /register/:id sits outside the auth gate (App.tsx), so a diver forwarding the
// link to a friend without an account sends them somewhere that renders the
// event and lets them sign up on the spot, rather than to a login wall. A shop
// with its own public event pages sets urls.eventPage, and the link goes there.
export function eventShareUrl(id: string): string {
  const template = siteConfig.urls.eventPage
  return template
    ? template.replace('{id}', encodeURIComponent(id))
    : `${siteConfig.urls.app}/register/${encodeURIComponent(id)}`
}
