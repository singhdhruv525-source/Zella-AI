import { Children, cloneElement, useEffect, useRef } from "react";

// Keyboard behaviour every dialog needs: focus moves into it when it opens (the element marked data-autofocus, or
// the first control), Tab and Shift+Tab stay inside it, Escape closes it (unless busy), and focus goes back to the
// control that opened it when it closes. Returns the ref for the dialog element.
const FOCUSABLE = 'a[href], button:not([disabled]), input:not([disabled]):not([type="hidden"]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';

// Open dialogs, newest last: only the topmost one handles Tab and Escape, so a confirmation opened over a drawer
// keeps the keyboard and the drawer underneath doesn't pull focus back out of it.
const OPEN = [];

export function useDialogFocus(onClose, busy = false) {
  const ref = useRef(null);
  const close = useRef(onClose);
  const isBusy = useRef(busy);
  close.current = onClose;
  isBusy.current = busy;

  useEffect(() => {
    const opener = document.activeElement;
    const box = ref.current;
    const items = () => [...(box?.querySelectorAll(FOCUSABLE) ?? [])].filter((el) => el.offsetParent !== null || el === document.activeElement);
    (box?.querySelector("[data-autofocus]") ?? items()[0] ?? box)?.focus?.();

    const me = {};
    OPEN.push(me);
    const onKey = (event) => {
      if (OPEN[OPEN.length - 1] !== me) return;   // another dialog is open on top of this one
      if (event.key === "Escape") {
        if (!isBusy.current && close.current) { event.stopPropagation(); close.current(); }
        return;
      }
      if (event.key !== "Tab" || !box) return;
      const list = items();
      if (!list.length) { event.preventDefault(); return; }
      const first = list[0], last = list[list.length - 1];
      if (event.shiftKey && (document.activeElement === first || !box.contains(document.activeElement))) { event.preventDefault(); last.focus(); }
      else if (!event.shiftKey && (document.activeElement === last || !box.contains(document.activeElement))) { event.preventDefault(); first.focus(); }
    };
    document.addEventListener("keydown", onKey, true);
    return () => {
      document.removeEventListener("keydown", onKey, true);
      const at = OPEN.indexOf(me);
      if (at >= 0) OPEN.splice(at, 1);
      if (opener && typeof opener.focus === "function" && document.contains(opener)) opener.focus();
    };
  }, []);

  return ref;
}

// The same for a dialog written inline: wraps its one element and gives it the ref. `onClose` may be null when the
// page already handles Escape itself (focus still moves in, stays in and goes back).
export function DialogFocus({ onClose = null, busy = false, children }) {
  const ref = useDialogFocus(onClose, busy);
  return cloneElement(Children.only(children), { ref, tabIndex: -1 });
}
