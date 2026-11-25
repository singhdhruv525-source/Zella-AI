import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { useDialogFocus } from "../useDialogFocus";
import { Icon } from "../BusinessUI";
import { sheetRelease } from "./phoneHelpers.js";
import { prefersReducedMotion } from "./usePhoneLayout.js";
import { lockBodyScroll } from "./bodyScrollLock.js";

// A bottom sheet for phones (P12, approved 25 Nov 2026). It opens at half height with a drag handle: drag it up for
// full height, down to go back or close. It also closes on Escape (unless busy), a tap outside or its close button.
// Focus moves in, stays in, and goes back to the control that opened it (useDialogFocus). A short sheet ("fit") takes
// only the height it needs. The page behind can't scroll while it is open.
//   size: "half" (default) | "full" | "fit"
export function BottomSheet({ title, description, onClose, busy = false, size = "half", children, footer, icon, tone, label, className = "", host }) {
  const [current, setCurrent] = useState(size);
  const [closing, setClosing] = useState(false);
  const [drag, setDrag] = useState(0);
  const dragging = useRef(null);
  const closed = useRef(false);

  // the close plays the slide down first (none with reduced motion), then tells the owner of the sheet
  const requestClose = () => {
    if (busy || closed.current) return;
    closed.current = true;
    setClosing(true);
    setTimeout(() => onClose?.(), prefersReducedMotion() ? 0 : 220);
  };
  const ref = useDialogFocus(requestClose, busy);

  useEffect(() => lockBodyScroll(), []);   // shared with the side panel (bodyScrollLock.js)

  const onPointerDown = (e) => {
    if (e.button !== undefined && e.button !== 0) return;
    // only the handle and the heading drag the sheet; the content scrolls as usual
    if (!e.target.closest(".pn-grab, .pn-sheet-head") || e.target.closest(".pn-sheet-head button")) return;
    dragging.current = { y: e.clientY, id: e.pointerId, moved: false, grab: Boolean(e.target.closest(".pn-grab")) };
    e.currentTarget.setPointerCapture?.(e.pointerId);
  };
  const onPointerMove = (e) => {
    const d = dragging.current;
    if (!d || d.id !== e.pointerId) return;
    const dy = e.clientY - d.y;
    if (Math.abs(dy) > 6) d.moved = true;
    if (d.moved) setDrag(current === "fit" ? Math.max(0, dy) : dy);
  };
  const onPointerUp = (e) => {
    const d = dragging.current;
    if (!d || d.id !== e.pointerId) return;
    dragging.current = null;
    const dy = e.clientY - d.y;
    setDrag(0);
    // a tap on the handle (the pointer is captured, so its click lands on the sheet): switch heights here
    if (!d.moved) { if (d.grab && e.type === "pointerup") toggle(); return; }
    const next = sheetRelease(current, dy);
    if (next === "close") requestClose(); else setCurrent(next);
  };
  // the browser took the gesture over (a scroll, a system gesture): forget the drag, never resize or close
  const onPointerCancel = (e) => {
    const d = dragging.current;
    if (!d || d.id !== e.pointerId) return;
    dragging.current = null;
    setDrag(0);
  };
  // the handle is a button too: Enter or Space switch between half and full height (a pointer tap is handled above)
  const toggle = () => setCurrent((c) => (c === "fit" ? c : c === "full" ? "half" : "full"));

  const sheet = (
    <div className={`pn-sheet-layer ${closing ? "closing" : ""}`}>
      <button type="button" className="pn-scrim on sheet" aria-label="Close" tabIndex={-1}
        onClick={() => requestClose()} />
      {/* once closing starts nothing inside can be used (inert), so a form can't be sent while it slides away and
          then lose its draft and its error when the close finishes */}
      <section ref={ref} tabIndex={-1} role="dialog" aria-modal="true" aria-label={label ?? (typeof title === "string" ? title : "Details")}
        inert={closing ? true : undefined}
        className={`pn-sheet ${current} ${closing ? "closing" : "open"} ${drag ? "dragging" : ""} ${className}`}
        style={!drag ? undefined : drag < 0 && current === "half" ? { height: `min(92dvh, calc(52dvh + ${-drag}px))` } : { "--pn-drag": `${drag}px` }}
        onPointerDown={onPointerDown} onPointerMove={onPointerMove} onPointerUp={onPointerUp} onPointerCancel={onPointerCancel}>
        {/* a sheet that fits its content has no other height: the handle is only a drag area, not a button */}
        {current === "fit"
          ? <span className="pn-grab" aria-hidden="true" />
          : <button type="button" className="pn-grab" aria-label={current === "full" ? "Show less" : "Show more"}
            aria-expanded={current === "full"} onClick={(e) => { if (e.detail === 0) toggle(); }} />}
        {(title || description) && (
          <div className="pn-sheet-head">
            {icon && <span className={`ba-modal-icon ${tone ?? ""}`}><Icon name={icon} /></span>}
            <div>
              {title && <h2>{title}</h2>}
              {description && <p>{description}</p>}
            </div>
            <button type="button" className="pn-iconbtn pn-sheet-close" onClick={requestClose} disabled={busy} aria-label="Close">
              <Icon name="close" />
            </button>
          </div>
        )}
        <div className="pn-sheet-body">{children}</div>
        {footer && <div className="pn-sheet-foot">{footer}</div>}
      </section>
    </div>
  );
  const target = host ?? (typeof document !== "undefined" ? document.querySelector(".ba-root, .owner-app, .ba-auth") ?? document.body : null);
  return target ? createPortal(sheet, target) : sheet;
}

// Dialogs the pages draw themselves (the booking panel, the admin's drawers and confirmations) become sheets on a
// phone the same way: styles/phone-nav.css draws them at the bottom with a handle, and this adds the drag. Nothing is
// added to their markup (React owns it); only a data attribute and listeners. Dragging them away sends Escape, which
// each of them already handles (useDialogFocus or their own key handler), so busy dialogs stay open as before.
const ENHANCED = ".bp-panel, .owner-modal[role=\"dialog\"], [role=\"dialog\"] .owner-modal, .owner-modal";
export function useSheetEnhancer(enabled) {
  useEffect(() => {
    if (!enabled || typeof MutationObserver === "undefined") return undefined;
    // one disposer per dialog: cleanup removes exactly the listeners added here, so turning phone mode off and on
    // again never leaves two sets (two drags, two Escapes)
    const attached = new Map();
    const attach = (el) => {
      if (attached.has(el) || el.closest(".pn-sheet")) return;
      const fit = el.classList.contains("bd-confirm");
      let size = fit ? "fit" : "half";
      el.dataset.pnSheet = size;
      let start = null, dy = 0;
      const head = (t) => t.closest(".bp-head, .ao-drawer-head, .owner-modal-header, .wiz-section-head");
      const down = (e) => {
        if (!el.dataset.pnSheet) return;   // back on a wider screen: a normal dialog again
        if (e.target.closest("button, a, input, select, textarea")) return;
        // the drag areas: the dialog's own drag strip (SheetGrip) and its heading, both touch-action: none
        if (!(e.target.closest(".pn-sheet-grip") || head(e.target))) return;
        start = { y: e.clientY, id: e.pointerId }; dy = 0;
        el.setPointerCapture?.(e.pointerId);
      };
      const move = (e) => {
        if (!start || start.id !== e.pointerId) return;
        dy = e.clientY - start.y;
        if (Math.abs(dy) <= 6) return;
        el.dataset.pnDragging = "1";
        if (dy < 0 && size === "half") el.style.setProperty("height", `min(92dvh, calc(52dvh + ${-dy}px))`, "important");
        else el.style.setProperty("--pn-drag", `${Math.max(0, dy)}px`);
      };
      const up = (e) => {
        if (!start || start.id !== e.pointerId) return;
        start = null;
        delete el.dataset.pnDragging;
        el.style.removeProperty("--pn-drag");
        el.style.removeProperty("height");
        if (Math.abs(dy) <= 6) return;
        const next = sheetRelease(size, dy);
        if (next === "close") document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
        else { size = next; el.dataset.pnSheet = size; }
      };
      el.addEventListener("pointerdown", down);
      el.addEventListener("pointermove", move);
      // cancelled by the browser: the drag is forgotten, the dialog stays as it was
      const cancel = (e) => {
        if (!start || start.id !== e.pointerId) return;
        start = null; dy = 0;
        delete el.dataset.pnDragging;
        el.style.removeProperty("--pn-drag");
        el.style.removeProperty("height");
      };
      el.addEventListener("pointerup", up);
      el.addEventListener("pointercancel", cancel);
      attached.set(el, () => {
        el.removeEventListener("pointerdown", down);
        el.removeEventListener("pointermove", move);
        el.removeEventListener("pointerup", up);
        el.removeEventListener("pointercancel", cancel);
        if (start) { try { el.releasePointerCapture?.(start.id); } catch { /* already released */ } }
        delete el.dataset.pnSheet;
        delete el.dataset.pnDragging;
        el.style.removeProperty("--pn-drag");
        el.style.removeProperty("height");
      });
    };
    // dialogs that have left the page are let go of (their listeners and the entry), so nothing is kept for them
    const scan = () => {
      attached.forEach((dispose, el) => { if (!el.isConnected) { dispose(); attached.delete(el); } });
      document.querySelectorAll(ENHANCED).forEach(attach);
    };
    scan();
    const mo = new MutationObserver(scan);
    mo.observe(document.body, { childList: true, subtree: true });
    return () => {
      mo.disconnect();
      attached.forEach((dispose) => dispose());
      attached.clear();
    };
  }, [enabled]);
}
