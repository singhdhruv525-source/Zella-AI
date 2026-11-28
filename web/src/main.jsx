import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './index.css'
import App from './App.jsx'
// Shared component look for every app; loaded after the app stylesheets so it wins ties.
import './styles/components.css'
// The optional Glass theme (Settings > Appearance); only active when <html data-zella-theme="glass">.
import './styles/glass.css'
// The Zella Voice theme (the default look) and the sidebar logo.
import './styles/zella-theme.css'
import './styles/brand.css'
// Motion for every page in both apps: buttons, cards, tabs, rows and popups (off with reduced motion).
import './styles/motion.css'
import './styles/motion.js'
// The business CRM's polish (25 Nov 2026): scoped to the CRM root, so the admin dashboard never changes.
import './styles/crm-polish.css'
// Admin pages polish (owner approved 25 Nov 2026): admin only, loaded last so it wins ties.
import './styles/admin-polish.css'
// The CRM look (25 Nov 2026, approved C items): scoped to the CRM root, so the admin dashboard never changes. Last.
import './styles/crm-look.css'
import { startAppearance } from './appearance'
import { ErrorBoundary } from './BusinessUI'
// Phone navigation for both apps (under 768 wide, approved 25 Nov 2026). Loaded last, so it sits on top of the polish.
import './styles/phone-nav.css'

startAppearance()

createRoot(document.getElementById('root')).render(
  <StrictMode>
    <ErrorBoundary fallback={() => (
      <main style={{ maxWidth: 520, margin: '15vh auto', padding: 24, fontFamily: 'system-ui, sans-serif', textAlign: 'center' }}>
        <h1 style={{ fontSize: 22 }}>This page stopped working</h1>
        <p>Zella Voice couldn't show this page. Nothing you saved was lost.</p>
        <p><button type="button" onClick={() => window.location.reload()}>Reload</button>{' '}<a href="/">Go to the start</a></p>
      </main>
    )}>
      <App />
    </ErrorBoundary>
  </StrictMode>,
)
