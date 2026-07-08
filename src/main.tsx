import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { siteConfig } from './config/site'
import './index.css'
import App from './App.tsx'

// Apply the fork's chosen design variant ('light' default, 'dark' dark ocean)
// as data-theme on <html> so the CSS palette/radius/font overrides in index.css
// take effect app-wide. Set before render so there's no first-paint flash.
document.documentElement.dataset.theme = siteConfig.theme.design ?? 'light'

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
