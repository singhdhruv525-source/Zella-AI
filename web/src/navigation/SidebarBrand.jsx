// The Zella Voice logo at the top of the sidebar (admin dashboard and CRM), from the official brand files in
// public/brand (never retyped or redrawn).
//
// Expanded: the full logo (wordmark, bars, VOICE). Collapsed (the dock, or the narrow rail on tablets): only the two
// bars, centred. The bars are one stable layer (zella-two-bars.svg, the same proportions as the bars inside the full
// logo) that sits exactly on the logo's own bars when expanded and slides to the centre when collapsed, while the
// wordmark fades and slides in or out around it. See styles/brand.css. The name is always there for screen readers.
// toggle: the shrink/expand arrow, shown at the top right of the logo (below the bars when collapsed).
export function SidebarBrand({ caption, toggle }) {
  return (
    <div className="zv-brand">
      <span className="zv-brand-logo" role="img" aria-label="Zella Voice">
        <img className="zv-brand-full zv-brand-light" src="/brand/zella-voice-logo-sidebar.png" alt="" draggable="false" />
        <img className="zv-brand-full zv-brand-dark" src="/brand/zella-voice-logo-sidebar-white.png" alt="" draggable="false" />
        <img className="zv-brand-mark" src="/brand/zella-two-bars.svg" alt="" draggable="false" />
      </span>
      {caption && <span className="zv-brand-caption">{caption}</span>}
      {toggle}
    </div>
  );
}
