import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './index.css'
import App from './App.jsx'
// Shared component look for every app; loaded after the app stylesheets so it wins ties.
import './styles/components.css'
// The optional Glass theme (Settings > Appearance); only active when <html data-zella-theme="glass">.
import './styles/glass.css'
import { startAppearance } from './appearance'

startAppearance()

createRoot(document.getElementById('root')).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
