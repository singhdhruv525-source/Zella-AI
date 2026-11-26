import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { Icon } from "../BusinessUI";
import { useDialogFocus } from "../useDialogFocus";
import { MORE_TAB, badgeText, tabName } from "./phoneTabs.js";
import { createPendingStore, createToastStore, panelDrag, panelReleaseCloses, rowDrag, rowReleaseOpens } from "./phoneHelpers.js";
import { prefersReducedMotion } from "./usePhoneLayout.js";
import { lockBodyScroll } from "./bodyScrollLock.js";

// The phone navigation for both apps (approved 25 Nov 2026, P1 to P29). Only drawn under 768 wide; the desktop
// sidebar and the tablet rail are untouched. Look: styles/phone-nav.css.

// ---------- Top bar (P9): one slim row ----------
export function PhoneTopBar({ children, actions, searchOpen, search }) {
  return (
    <header className="pn-top">
      <div className="pn-top-row">
        {children}
        <div className="pn-top-actions">{actions}</div>
      </div>
      {searchOpen && <div className="pn-top-search">{search}</div>}
    </header>
  );
}

// ---------- Bottom bar (P1 to P5, P15) ----------
// tabs: [{ key, label, icon, count, countNoun }]. Tapping the open tab scrolls back to the top.
export function BottomBar({ tabs, selected, onSelect, onMore, moreOpen, moreCount, moreNoun = "to review", label = "Main" }) {
  const all = [...tabs, { ...MORE_TAB, count: moreCount, countNoun: moreNoun }];
  return (
    <nav className="pn-tabbar" aria-label={label} style={{ "--pn-cols": all.length }}>
      {all.map((t) => {
        const isMore = t.key === MORE_TAB.key;
        const current = selected === t.key;
        const count = t.countState === "failed" ? "!" : badgeText(t.count);
        return (
          <button key={t.key} type="button" className="pn-tab" data-tab={t.key}
            aria-current={current ? "page" : undefined}
            aria-expanded={isMore ? Boolean(moreOpen) : undefined}
            aria-haspopup={isMore ? "dialog" : undefined}
            aria-label={tabName(t.label, t.count, t.countNoun, t.countState)}
            onClick={(e) => (isMore ? onMore(e.currentTarget) : onSelect(t.key))}>
            <span className="pn-ic">
              <Icon name={t.icon} />
              {count && <span className={`pn-count ${t.countState === "failed" || t.countState === "stale" ? t.countState : ""}`} aria-hidden="true">{count}</span>}
            </span>
            <span aria-hidden="true">{t.label}</span>
          </button>
        );
      })}
    </nav>
  );
}

// Everything pinned above the bar, in order: the page's main action (P10), the live strip (P13), then the bar.
export function PhoneBottom({ action, strip, bar, hidden }) {
  return (
    <div className="pn-bottom" inert={hidden ? true : undefined}>
      {action && <div className="pn-action">{action}</div>}
      {strip}
      {bar}
    </div>
  );
}

// ---------- Live strip (P13): something happening now ----------
export function LiveStrip({ title, sub, action, onAction }) {
  return (
    <button type="button" className="pn-strip" onClick={onAction} aria-label={`${title}. ${sub}. ${action}`}>
      <span className="pn-live" aria-hidden="true" />
      <span className="pn-strip-text" aria-hidden="true"><b>{title}</b><small>{sub}</small></span>
      <span className="pn-strip-go" aria-hidden="true">{action}<Icon name="chevron_right" size="sm" /></span>
    </button>
  );
}

// ---------- Side panel (P6 to P8) ----------
// Stays in the page so it can slide; while open, focus is kept inside (useDialogFocus through PanelFocus), the page
// behind is inert, and Escape, the backdrop, a swipe to the left or choosing a page close it. Focus then goes back to
// More (the control that opened it).
export function SidePanel({ open, onClose, children, head }) {
  const box = useRef(null);
  const [drag, setDrag] = useState(0);
  const start = useRef(null);
  const down = (e) => { if (e.pointerType === "mouse" && e.button !== 0) return; start.current = { x: e.clientX, y: e.clientY, id: e.pointerId, horizontal: null }; };
  const move = (e) => {
    const s = start.current;
    if (!s || s.id !== e.pointerId) return;
    const dx = e.clientX - s.x, dy = e.clientY - s.y;
    if (s.horizontal === null && (Math.abs(dx) > 8 || Math.abs(dy) > 8)) {
      s.horizontal = Math.abs(dx) > Math.abs(dy);
      if (s.horizontal) box.current?.setPointerCapture?.(e.pointerId);
    }
    if (s.horizontal) setDrag(panelDrag(dx));
  };
  const up = (e) => {
    const s = start.current;
    if (!s || s.id !== e.pointerId) return;
    start.current = null;
    const dx = e.clientX - s.x;
    setDrag(0);
    if (s.horizontal && panelReleaseCloses(dx)) onClose();
  };
  // the browser took the gesture over: the drag is forgotten, the panel stays open (decisions are made on release)
  const cancel = (e) => {
    const s = start.current;
    if (!s || s.id !== e.pointerId) return;
    start.current = null;
    setDrag(0);
  };
  return (
    <>
      {/* pointer only: the panel has its own Close button, so the backdrop is hidden from screen readers and inert
          while the panel is closed */}
      <button type="button" className={`pn-scrim panel ${open ? "on" : ""}`} aria-hidden="true" tabIndex={-1}
        inert={open ? undefined : true} onClick={onClose} style={drag ? { opacity: Math.max(0, 1 + drag / 320) } : undefined} />
      <aside ref={box} id="pn-panel" className={`pn-panel ${open ? "on" : ""} ${drag ? "dragging" : ""}`}
        role="dialog" aria-modal="true" aria-label="Menu" aria-hidden={open ? undefined : true} inert={open ? undefined : true}
        tabIndex={-1} style={drag ? { "--pn-drag": `${drag}px` } : undefined}
        onPointerDown={down} onPointerMove={move} onPointerUp={up} onPointerCancel={cancel}>
        <div className="pn-panel-head">
          {head}
          <button type="button" className="pn-iconbtn pn-panel-close" onClick={onClose} aria-label="Close menu" data-autofocus>
            <Icon name="close" />
          </button>
        </div>
        <div className="pn-panel-scroll">{children}</div>
      </aside>
      {open && <PanelFocus box={box} onClose={onClose} />}
    </>
  );
}

// Focus handling for the open panel: the same hook every dialog uses, pointed at the panel.
function PanelFocus({ box, onClose }) {
  const ref = useDialogFocus(onClose);
  // the panel element is always in the page; point the hook at it before the hook's own effect starts
  useLayoutEffect(() => { ref.current = box.current; }, [ref, box]);
  // the page behind doesn't scroll while the panel is open; the earlier value comes back when it closes
  useEffect(() => lockBodyScroll(), []);   // shared with the sheets (bodyScrollLock.js)
  // The panel was hidden until this render; the browser can refuse focus until it has drawn it, so check once more
  // on the next frame.
  useEffect(() => {
    const id = requestAnimationFrame(() => {
      const panel = box.current;
      if (panel && !panel.contains(document.activeElement)) panel.querySelector("[data-autofocus]")?.focus();
    });
    return () => cancelAnimationFrame(id);
  }, [box]);
  return null;
}

// Account rows at the bottom of the panel (P8).
export function PanelAccount({ name, detail, initials, rows }) {
  return (
    <div className="pn-account">
      <div className="pn-account-who">
        <span className="ba-avatar" aria-hidden="true">{initials}</span>
        <span><strong>{name}</strong>{detail && <small>{detail}</small>}</span>
      </div>
      {rows.map((r) => (
        <button key={r.label} type="button" className="pn-row-link" onClick={r.onClick}>
          <Icon name={r.icon} /><span>{r.label}</span>
        </button>
      ))}
    </div>
  );
}

// ---------- Toast above the bar (P21), with Undo when the change can be undone (P19) ----------
// One toast per app ("crm", "admin"), kept outside the workspace like the quick changes it offers to undo: switching
// business remounts the workspace, and a toast still in its time keeps a working Undo there.
const TOASTS = {};
function toastStoreFor(scope) {
  if (!TOASTS[scope]) TOASTS[scope] = createToastStore();
  return TOASTS[scope];
}
export function useToast(scope = "app") {
  const store = toastStoreFor(scope);
  const [toast, setToast] = useState(store.get);
  useEffect(() => { setToast(store.get()); return store.subscribe(setToast); }, [store]);
  return { toast, show: store.show, dismiss: store.dismiss };
}

export function Toast({ toast, onDismiss }) {
  return (
    // a companion of any open dialog (useDialogFocus): above dialogs and sheets, and in their Tab order, so its Undo
    // stays reachable while a dialog is open
    <div className={`pn-toast ${toast ? "on" : ""} ${toast?.tone ?? ""}`} role="status" aria-live="polite" data-dialog-companion>
      {toast && (
        <>
          <span>{toast.text}</span>
          {toast.undo
            ? <button type="button" onClick={() => { toast.undo(); onDismiss(); }}>Undo</button>
            : <button type="button" className="pn-toast-close" aria-label="Dismiss" onClick={onDismiss}><Icon name="close" size="sm" /></button>}
        </>
      )}
    </div>
  );
}

// ---------- Skeleton (P18): grey shapes while a page loads ----------
export function Skeleton({ rows = 4, label = "Loading" }) {
  return (
    <div className="pn-skel" role="status" aria-busy="true" aria-label={label}>
      <i /><i />
      {Array.from({ length: rows }, (_, n) => <i key={n} />)}
    </div>
  );
}

// ---------- Pull to refresh indicator (P17) ----------
export function PullIndicator({ distance, refreshing }) {
  const on = refreshing || distance > 0;
  return (
    <div className={`pn-ptr ${on ? "on" : ""}`} style={!refreshing && distance ? { height: `${distance}px` } : undefined} role="status" aria-live="polite">
      {on && <><Icon name="refresh" size="sm" className={refreshing ? "pn-spin" : ""} /><span>{refreshing ? "Refreshing" : distance >= 48 ? "Let go to refresh" : "Pull to refresh"}</span></>}
    </div>
  );
}

// ---------- Swipe row (P20) ----------
// Swipe left (pointer events) to show the row's actions. Every action is also reachable without swiping: the row
// keeps its own visible buttons, and the tray buttons are only in the tab order while the tray is open.
//   actions: [{ key, label, icon, tone: "call" | "done" | "info", onClick, href }]
export function SwipeRow({ actions = [], children, className = "", label }) {
  const tray = actions.length * 76;
  const [offset, setOffset] = useState(0);
  const [open, setOpen] = useState(false);
  const [dragging, setDragging] = useState(false);
  const start = useRef(null);
  const suppressClick = useRef(false);
  const close = () => { setOpen(false); setOffset(0); };
  const down = (e) => {
    if (!tray || (e.pointerType === "mouse" && e.button !== 0)) return;
    start.current = { x: e.clientX, y: e.clientY, id: e.pointerId, horizontal: null };
  };
  const move = (e) => {
    const s = start.current;
    if (!s || s.id !== e.pointerId) return;
    const dx = e.clientX - s.x, dy = e.clientY - s.y;
    if (s.horizontal === null && (Math.abs(dx) > 8 || Math.abs(dy) > 8)) {
      s.horizontal = Math.abs(dx) > Math.abs(dy);
      if (s.horizontal) { e.currentTarget.setPointerCapture?.(e.pointerId); setDragging(true); }
    }
    if (s.horizontal) setOffset(rowDrag(dx, open, tray));
  };
  const up = (e) => {
    const s = start.current;
    if (!s || s.id !== e.pointerId) return;
    start.current = null;
    setDragging(false);
    if (!s.horizontal) return;
    suppressClick.current = true;   // the drag ends with a click on the row; it must not open it
    setTimeout(() => { suppressClick.current = false; }, 0);
    const opens = rowReleaseOpens(rowDrag(e.clientX - s.x, open, tray));
    setOpen(opens);
    setOffset(opens ? -tray : 0);
  };
  // cancelled by the browser: the row goes back to where it was (open or closed), nothing is decided
  const cancel = (e) => {
    const s = start.current;
    if (!s || s.id !== e.pointerId) return;
    start.current = null;
    setDragging(false);
    setOffset(open ? -tray : 0);
  };
  return (
    <li className={`pn-swipe ${open ? "open" : ""} ${className}`} aria-label={label}>
      {tray > 0 && (
        <div className="pn-swipe-actions" aria-hidden={open ? undefined : true}>
          {actions.map((a) => {
            const props = { className: a.tone ?? "", tabIndex: open ? 0 : -1, onClick: (e) => { close(); a.onClick?.(e); } };
            const inner = <><Icon name={a.icon} /><span>{a.label}</span></>;
            return a.href ? <a key={a.key} {...props} href={a.href}>{inner}</a> : <button key={a.key} type="button" {...props}>{inner}</button>;
          })}
        </div>
      )}
      <div className={`pn-item-wrap ${dragging ? "dragging" : ""}`}
        style={offset ? { transform: `translateX(${offset}px)` } : undefined}
        onPointerDown={down} onPointerMove={move} onPointerUp={up} onPointerCancel={cancel}
        onClickCapture={(e) => {
          // the click that ends a drag is not a tap on the row; a tap while the tray is open just closes it
          if (suppressClick.current) { e.preventDefault(); e.stopPropagation(); return; }
          if (open) { e.preventDefault(); e.stopPropagation(); close(); }
        }}>
        {children}
      </div>
    </li>
  );
}

// ---------- Tabs that keep their state (P16) ----------
// Each tab page visited stays in the page, hidden while another is open, so its filters, search and loaded list are
// there when you come back. Pages from the side panel are drawn as usual and leave when you go elsewhere.
//   active: the open tab's key, or null when the open page is not a tab
export function TabStack({ tabs, active, render }) {
  const [visited, setVisited] = useState(() => (active ? [active] : []));
  const keys = tabs.map((t) => t.key);
  if (active && !visited.includes(active)) setVisited([...visited, active]);
  return visited.filter((k) => keys.includes(k)).map((k) => (
    <div key={k} className="pn-tabpage" data-tab-page={k} hidden={k !== active}>{render(k)}</div>
  ));
}

// Scroll memory per tab (P16): the page scroll is recorded for the open tab and put back when you return to it; a
// page from the panel starts at the top. The restore runs before the browser paints, so nothing jumps.
export function useTabScroll(enabled, key, memory, isTab) {
  const current = useRef({ key, isTab });
  const last = useRef(key);
  useLayoutEffect(() => {
    current.current = { key, isTab };
    if (!enabled || last.current === key) { last.current = key; return; }
    last.current = key;
    window.scrollTo({ top: isTab ? memory.read(key).scroll ?? 0 : 0, behavior: "instant" });
  }, [enabled, key, memory, isTab]);
  useEffect(() => {
    if (!enabled) return undefined;
    const on = () => { const c = current.current; if (c.isTab) memory.save(c.key, { scroll: window.scrollY }); };
    window.addEventListener("scroll", on, { passive: true });
    return () => window.removeEventListener("scroll", on);
  }, [enabled, memory]);
}

export const scrollToTop = () => window.scrollTo({ top: 0, behavior: prefersReducedMotion() ? "instant" : "smooth" });

// The app's store of quick changes waiting for their Undo window (phoneHelpers createPendingStore). Each change still
// goes out when its own window ends; closing the page sends what is waiting, and so does leaving the app.
// One store per app ("crm", "admin"), kept for the life of the browser tab: switching business remounts the
// workspace, and a change waiting then still has its full window and is sent by its own timer (never early). Only a
// real departure (pagehide, not kept in the back/forward cache) sends what is waiting at once; signing out sends it
// first, on purpose, so nothing is lost (see sendWaitingChanges). A page kept in the back/forward cache sends nothing
// early: back again (pageshow), the changes carry on to their original Undo deadlines.
const STORES = {};
export function pendingStoreFor(scope) {
  if (!STORES[scope]) {
    STORES[scope] = createPendingStore();
    if (typeof window !== "undefined") {
      // leaving for good: each waiting change goes out as a keepalive request the browser lets finish (best effort);
      // kept in the back/forward cache: nothing is sent early
      window.addEventListener("pagehide", (e) => { STORES[scope].onPageHide(e.persisted); });
      // back from the back/forward cache: the waiting changes resume to their original deadlines
      window.addEventListener("pageshow", (e) => { STORES[scope].onPageShow(e.persisted); });
      // a waiting change that can't be sent that way right now (no beacon, or no session token): the browser asks
      // before the tab closes
      window.addEventListener("beforeunload", (e) => {
        if (!STORES[scope].waitingWithoutBeacon()) return;
        e.preventDefault();
        e.returnValue = "";
      });
    }
  }
  return STORES[scope];
}
export const usePendingStore = (scope) => pendingStoreFor(scope);
// Before signing out: send what is still waiting while the session is still valid.
export async function sendWaitingChanges(store) {
  try { await store.flushAll(); } catch { /* each change reports its own failure */ }
}

// A page's view of the store: redrawn on every change; `onSent(id)` runs for a change sent while the page is open.
// page: which page this is ("today", "tasks", "support"); its reads acknowledge settled changes for it only.
export function usePendingViews(store, onSent, page = "page") {
  const [, setVersion] = useState(0);
  const latest = useRef(onSent);
  useLayoutEffect(() => { latest.current = onSent; });
  useEffect(() => store?.subscribe((event) => {
    setVersion((n) => n + 1);
    if (event.type === "sent") latest.current?.(event.id);
  }), [store]);
  useEffect(() => store?.register(page), [store, page]);
  return store ? store.views(page) : new Map();
}
