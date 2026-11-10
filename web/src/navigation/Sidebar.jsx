import { useEffect, useRef, useState } from "react";
import { Icon, Modal, Pill } from "../BusinessUI";

// The CRM sidebar: groups and items come from buildNavigation (navConfig.js). Groups can be folded; an item with
// sub-items opens in place. The group or item holding the current page always stays open.

const FOLD_KEY = "zella.nav.folded";
const readFolded = () => {
  try { return new Set(JSON.parse(localStorage.getItem(FOLD_KEY) ?? "[]")); } catch { return new Set(); }
};
const saveFolded = (set) => {
  try { localStorage.setItem(FOLD_KEY, JSON.stringify([...set])); } catch { /* private mode: folding still works this visit */ }
};

export function SidebarNav({ groups, isActive, onOpen, badges }) {
  const [folded, setFolded] = useState(readFolded);
  const [openItems, setOpenItems] = useState(() => new Set());
  const holds = (item) => isActive(item) || (item.children ?? []).some(isActive);

  const toggleGroup = (id) => setFolded((s) => {
    const next = new Set(s);
    if (next.has(id)) next.delete(id); else next.add(id);
    saveFolded(next);
    return next;
  });
  const toggleItem = (id) => setOpenItems((s) => {
    const next = new Set(s);
    if (next.has(id)) next.delete(id); else next.add(id);
    return next;
  });

  const badge = (item) => {
    const n = item.badge ? badges[item.badge] ?? 0 : 0;
    return n > 0 ? <span className="ba-count" aria-label={`${n} waiting`}>{n > 99 ? "99+" : n}</span> : null;
  };

  return groups.map((group) => {
    const current = group.items.some(holds);
    const isFolded = folded.has(group.id) && !current;
    const listId = `nav-group-${group.id}`;
    return (
      <div key={group.id} className={`ba-nav-section ${isFolded ? "folded" : ""}`}>
        <button type="button" className="ba-nav-group" aria-expanded={!isFolded} aria-controls={listId} onClick={() => toggleGroup(group.id)}>
          <span>{group.label}</span>
          <Icon name={isFolded ? "chevron_right" : "expand_more"} size="sm" />
        </button>
        {/* Folded groups stay in the page but hidden, so the icon-only sidebar on tablets still lists them. */}
        {(
          <nav className="ba-nav" id={listId} aria-label={group.label}>
            {group.notice && <p className="ba-nav-notice">{group.notice}</p>}
            {group.items.map((item) => {
              if (!item.children) {
                return (
                  <button key={item.id} type="button" className={`ba-nav-item ${isActive(item) ? "active" : ""}`}
                    aria-current={isActive(item) ? "page" : undefined} title={item.label} onClick={() => onOpen(item)}>
                    <Icon name={item.icon} />
                    <span>{item.label}</span>
                    {badge(item)}
                  </button>
                );
              }
              const open = openItems.has(item.id) || item.children.some(isActive);
              const subId = `nav-sub-${item.id}`;
              return (
                <div key={item.id} className="ba-nav-parent">
                  <button type="button" className={`ba-nav-item ${item.children.some(isActive) ? "holds" : ""}`} aria-expanded={open} aria-controls={subId}
                    title={item.label} onClick={() => toggleItem(item.id)}>
                    <Icon name={item.icon} />
                    <span>{item.label}</span>
                    {!open && badge(item)}
                    <Icon name={open ? "expand_less" : "expand_more"} size="sm" className="ba-nav-chev" />
                  </button>
                  {open && (
                    <div className="ba-nav-children" id={subId}>
                      {item.children.map((child) => (
                        <button key={child.id} type="button" className={`ba-nav-item sub ${isActive(child) ? "active" : ""}`}
                          aria-current={isActive(child) ? "page" : undefined} title={child.label} onClick={() => onOpen(child)}>
                          <Icon name={child.icon} size="sm" />
                          <span>{child.label}</span>
                          {badge(child)}
                        </button>
                      ))}
                    </div>
                  )}
                </div>
              );
            })}
          </nav>
        )}
      </div>
    );
  });
}

// Shown while a business's configuration loads, or when it couldn't be loaded.
export function SidebarState({ status, error, onRetry }) {
  if (status === "loading") {
    return (
      <div className="ba-nav-skeleton" aria-busy="true" aria-label="Loading menu">
        {Array.from({ length: 8 }, (_, n) => <span key={n} style={{ width: `${55 + ((n * 17) % 35)}%` }} />)}
      </div>
    );
  }
  return (
    <div className="ba-nav-error" role="alert">
      <strong>Menu couldn't load</strong>
      <span>This business's settings didn't load{error ? ` (${error})` : ""}. Nothing is shown until they do.</span>
      <button type="button" className="ba-btn sm" onClick={onRetry}><Icon name="refresh" size="sm" />Try again</button>
    </div>
  );
}

// A small menu that opens under its button and closes on Escape or a click elsewhere.
function useMenu() {
  const [open, setOpen] = useState(false);
  const ref = useRef(null);
  useEffect(() => {
    if (!open) return undefined;
    const onDown = (e) => { if (ref.current && !ref.current.contains(e.target)) setOpen(false); };
    const onKey = (e) => { if (e.key === "Escape") setOpen(false); };
    document.addEventListener("mousedown", onDown);
    window.addEventListener("keydown", onKey);
    return () => { document.removeEventListener("mousedown", onDown); window.removeEventListener("keydown", onKey); };
  }, [open]);
  return { open, setOpen, ref };
}

const initialsOf = (name) => (name || "?").split(/\s+/).filter(Boolean).slice(0, 2).map((w) => w[0].toUpperCase()).join("");

// Top bar: the business, its industry and location, and a menu to switch business or open its settings.
export function BusinessSwitcher({ workspace, workspaces, config, onSwitch, onGo, canManage }) {
  const { ref, ...menu } = useMenu();
  const subtitle = [config?.industry?.name ?? workspace.industry, config?.location].filter(Boolean).join(" • ");
  const others = workspaces.filter((w) => w.id !== workspace.id);
  return (
    <div className="ba-switcher" ref={ref}>
      <button type="button" className="ba-switcher-btn" aria-haspopup="menu" aria-expanded={menu.open} onClick={() => menu.setOpen(!menu.open)}>
        {config?.logo_url ? <img src={config.logo_url} alt="" className="ba-switcher-logo" /> : <span className="ba-switcher-logo">{initialsOf(workspace.name)}</span>}
        <span className="ba-switcher-text">
          <strong>{workspace.name}</strong>
          {subtitle && <small>{subtitle}</small>}
        </span>
        <Icon name="expand_more" size="sm" />
      </button>
      {menu.open && (
        <div className="ba-menu" role="menu">
          {others.length > 0 && <div className="ba-menu-label">Switch business</div>}
          {others.map((w) => (
            <button key={w.id} type="button" role="menuitem" className="ba-menu-item" onClick={() => { menu.setOpen(false); onSwitch(w.id); }}>
              <span className="ba-switcher-logo sm">{initialsOf(w.name)}</span>
              <span><strong>{w.name}</strong><small>{w.industry ?? "Industry not set"} · {w.role}</small></span>
            </button>
          ))}
          {others.length > 0 && <div className="ba-menu-sep" />}
          <button type="button" role="menuitem" className="ba-menu-item" onClick={() => { menu.setOpen(false); onGo("settings/profile/info"); }}>
            <Icon name="storefront" size="sm" /><span>Business profile</span>
          </button>
          <button type="button" role="menuitem" className="ba-menu-item" onClick={() => { menu.setOpen(false); onGo("settings/industry/modules"); }}>
            <Icon name="widgets" size="sm" /><span>Modules and industry</span>
          </button>
          {canManage && (
            <button type="button" role="menuitem" className="ba-menu-item" onClick={() => { menu.setOpen(false); onGo("settings/team/members"); }}>
              <Icon name="group_add" size="sm" /><span>Team members</span>
            </button>
          )}
          <button type="button" role="menuitem" className="ba-menu-item" onClick={() => { menu.setOpen(false); onGo("settings/billing/plan"); }}>
            <Icon name="credit_card" size="sm" /><span>Plan and billing</span>
          </button>
        </div>
      )}
    </div>
  );
}

// Top bar, right: who is signed in, their role, and their own settings.
export function ProfileMenu({ email, name, role, onGo, onSignOut }) {
  const { ref, ...menu } = useMenu();
  return (
    <div className="ba-profile" ref={ref}>
      <button type="button" className="ba-profile-btn" aria-haspopup="menu" aria-expanded={menu.open} onClick={() => menu.setOpen(!menu.open)}>
        <span className="ba-avatar">{initialsOf(name || email)}</span>
        <span className="ba-profile-text"><strong title={email}>{name || email}</strong><small>{role}</small></span>
        <Icon name="expand_more" size="sm" />
      </button>
      {menu.open && (
        <div className="ba-menu right" role="menu">
          <div className="ba-menu-label" title={email}>{email}</div>
          <button type="button" role="menuitem" className="ba-menu-item" onClick={() => { menu.setOpen(false); onGo("settings/me/profile"); }}>
            <Icon name="person" size="sm" /><span>My profile</span>
          </button>
          <button type="button" role="menuitem" className="ba-menu-item" onClick={() => { menu.setOpen(false); onGo("settings/me/security"); }}>
            <Icon name="lock" size="sm" /><span>Password and security</span>
          </button>
          <button type="button" role="menuitem" className="ba-menu-item" onClick={() => { menu.setOpen(false); onGo("settings/me/appearance"); }}>
            <Icon name="palette" size="sm" /><span>Appearance and theme</span>
          </button>
          <div className="ba-menu-sep" />
          <button type="button" role="menuitem" className="ba-menu-item" onClick={() => { menu.setOpen(false); onSignOut(); }}>
            <Icon name="logout" size="sm" /><span>Sign out</span>
          </button>
        </div>
      )}
    </div>
  );
}

// Bottom of the sidebar: the AI receptionist's state and a way to hear it.
export function ReceptionistCard({ workspace, agent, term, onTest }) {
  return (
    <div className="ba-agent-card">
      <div className="ba-agent-row">
        <span className="ba-agent-avatar"><Icon name="support_agent" size="sm" /></span>
        <div className="ba-agent-name">
          <strong>{workspace.receptionist?.name ?? "AI Receptionist"}</strong>
          <Pill tone={agent.tone} dot={agent.live} pulse={agent.live}>{agent.label}</Pill>
        </div>
      </div>
      <span>{agent.live
        ? `Handling calls, ${term("appointments").toLowerCase()} and ${term("customer").toLowerCase()} questions 24/7`
        : "Zella connects your phone line before it goes live"}</span>
      <button type="button" className="ba-btn block" onClick={onTest}><Icon name="call" size="sm" />Test AI Voice</button>
    </div>
  );
}

// Test AI Voice: a real call to the business's own Zella number. There is no in-browser call yet, so nothing here
// pretends to place one.
export function TestVoiceModal({ workspace, phone, agent, onClose, onGo }) {
  const name = workspace.receptionist?.name ?? "your AI receptionist";
  return (
    <Modal title="Test AI Voice" description={`Hear ${name} the way your callers do.`} onClose={onClose}
      footer={<>
        <button type="button" className="ba-btn" onClick={() => { onClose(); onGo("settings/receptionist/testing"); }}>Testing checklist</button>
        {phone && <a className="ba-btn primary" href={`tel:${phone}`}><Icon name="call" size="sm" />Call {phone}</a>}
      </>}>
      <div className="ba-modal-body">
        {phone ? (
          <>
            <p className="ba-note">Call your Zella number from your own phone: <strong>{phone}</strong></p>
            {!agent.live && <div className="ba-banner">The receptionist isn't live yet, so the call may not be answered by Zella.</div>}
            <ul className="ba-test-list">
              <li>Ask for your opening hours.</li>
              <li>Book a time, then check it appears in your Calendar.</li>
              <li>Ask to speak to a person.</li>
              <li>Ask something it shouldn't know, and check it says so.</li>
            </ul>
            <p className="ba-muted">Test calls are real calls: they appear in Calls and count toward your AI minutes.</p>
          </>
        ) : (
          <p className="ba-note">No Zella phone number is connected to this business yet. The Zella team connects it; once it's live you can call it from here.</p>
        )}
      </div>
    </Modal>
  );
}
