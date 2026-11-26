import { useCallback, useEffect, useLayoutEffect, useRef, useState, useSyncExternalStore } from "react";
import { PHONE_QUERY } from "./phoneTabs.js";
import { keyboardOpen, pullDistance, pullReleaseRefreshes } from "./phoneHelpers.js";

// Browser side of the phone navigation (approved 25 Nov 2026): is this a phone, is the keyboard open, reduced motion,
// and pull to refresh. Everything here is off above 767 wide, so tablets and desktops never change.

function mediaStore(query) {
  return {
    subscribe(cb) {
      if (typeof window === "undefined" || !window.matchMedia) return () => {};
      const mq = window.matchMedia(query);
      mq.addEventListener?.("change", cb);
      return () => mq.removeEventListener?.("change", cb);
    },
    get() { return typeof window !== "undefined" && Boolean(window.matchMedia?.(query).matches); },
  };
}
const PHONE = mediaStore(PHONE_QUERY);
const REDUCED = mediaStore("(prefers-reduced-motion: reduce)");

// True under 768 wide.
export function usePhoneLayout() {
  return useSyncExternalStore(PHONE.subscribe, PHONE.get, () => false);
}
export function useReducedMotion() {
  return useSyncExternalStore(REDUCED.subscribe, REDUCED.get, () => false);
}
export const prefersReducedMotion = () => REDUCED.get();

// Marks <html> while a phone layout is shown, so the rules in styles/phone-nav.css (and dialogs drawn at the top of
// the page) apply only then. `kind` is "crm" or "admin".
export function usePhoneRoot(phone, kind) {
  useEffect(() => {
    if (!phone) return undefined;
    const root = document.documentElement;
    root.classList.add("pn-phone");
    root.dataset.pnApp = kind;
    return () => { root.classList.remove("pn-phone", "pn-kb", "pn-has-strip", "pn-has-action"); delete root.dataset.pnApp; };
  }, [phone, kind]);
}

// A class on <html> while something is on screen (the sticky action, the live strip), so the page keeps room for it.
export function useRootFlag(name, on) {
  useEffect(() => {
    if (!on) return undefined;
    document.documentElement.classList.add(name);
    return () => document.documentElement.classList.remove(name);
  }, [name, on]);
}

// P23: the bar hides while the on screen keyboard is open. The visual viewport shrinks when it opens; a text field
// taking focus on a touch screen is the earlier sign, before the viewport has resized.
export function useKeyboardOpen(enabled) {
  const [open, setOpen] = useState(false);
  useEffect(() => {
    if (!enabled) return undefined;
    const vv = window.visualViewport;
    const root = document.documentElement;
    const set = (v) => { setOpen(v); root.classList.toggle("pn-kb", v); };
    const check = () => set(keyboardOpen(window.innerHeight, vv?.height));
    const typing = (el) => el?.matches?.('input:not([type="checkbox"]):not([type="radio"]):not([type="button"]):not([type="submit"]):not([type="date"]):not([type="time"]), textarea, [contenteditable="true"]');
    const onIn = (e) => { if (typing(e.target) && window.matchMedia("(pointer: coarse)").matches) set(true); };
    let outTimer = null;   // cleared when the hook stops, so check never runs after it
    const onOut = () => { clearTimeout(outTimer); outTimer = setTimeout(() => { if (!typing(document.activeElement)) check(); }, 0); };
    vv?.addEventListener("resize", check);
    document.addEventListener("focusin", onIn);
    document.addEventListener("focusout", onOut);
    // start from what the screen shows now (a field may already have focus when this turns on)
    if (typing(document.activeElement) && window.matchMedia("(pointer: coarse)").matches) set(true); else check();
    return () => {
      vv?.removeEventListener("resize", check);
      document.removeEventListener("focusin", onIn);
      document.removeEventListener("focusout", onOut);
      clearTimeout(outTimer);
      root.classList.remove("pn-kb");
      setOpen(false);   // turned off: no keyboard state carries over to the next time it turns on
    };
  }, [enabled]);
  return enabled && open;
}

// P17: pull to refresh. Pulling down while the page is at the top shows the indicator; letting go past the line calls
// onRefresh (which may return a promise). Touch events, because the browser takes over pointer events as soon as it
// starts scrolling. The browser's own pull to refresh is turned off while this is on (overscroll-behavior in CSS).
export function usePullToRefresh({ enabled, onRefresh }) {
  const [state, setState] = useState({ distance: 0, refreshing: false });
  const latest = useRef(onRefresh);
  useLayoutEffect(() => { latest.current = onRefresh; });
  const refreshing = useRef(false);
  useEffect(() => {
    if (!enabled) return undefined;
    let startY = null, startX = 0, distance = 0;
    const blocked = (t) => t.closest?.('[role="dialog"], .pn-panel, .pn-bottom, input, textarea, select, .ba-table-wrap, .owner-table-wrap');
    const start = (e) => {
      if (refreshing.current) { startY = null; return; }
      if (window.scrollY > 0 || e.touches.length !== 1 || blocked(e.target)) {
        // an interrupted pull (a second finger, a scroll, a dialog) forgets the shown distance, as a sideways drag does
        startY = null; distance = 0; setState((s) => (s.distance === 0 ? s : { ...s, distance: 0 })); return;
      }
      startY = e.touches[0].clientY; startX = e.touches[0].clientX; distance = 0;
    };
    const move = (e) => {
      if (startY === null) return;
      const dy = e.touches[0].clientY - startY;
      if (Math.abs(e.touches[0].clientX - startX) > Math.abs(dy) || window.scrollY > 0) { startY = null; setState((s) => ({ ...s, distance: 0 })); return; }
      distance = pullDistance(dy);
      setState((s) => (s.distance === distance ? s : { ...s, distance }));
    };
    const end = async () => {
      if (startY === null) return;
      startY = null;
      if (!pullReleaseRefreshes(distance)) { setState({ distance: 0, refreshing: false }); return; }
      refreshing.current = true;
      setState({ distance: 0, refreshing: true });
      try { await Promise.all([latest.current?.(), new Promise((r) => setTimeout(r, 600))]); }
      finally { refreshing.current = false; setState({ distance: 0, refreshing: false }); }
    };
    window.addEventListener("touchstart", start, { passive: true });
    window.addEventListener("touchmove", move, { passive: true });
    // the browser took the touch over: the pull is forgotten, nothing is refreshed
    const cancel = () => { startY = null; distance = 0; setState((s) => (s.distance === 0 ? s : { ...s, distance: 0 })); };
    window.addEventListener("touchend", end);
    window.addEventListener("touchcancel", cancel);
    return () => {
      window.removeEventListener("touchstart", start);
      window.removeEventListener("touchmove", move);
      window.removeEventListener("touchend", end);
      window.removeEventListener("touchcancel", cancel);
    };
  }, [enabled]);
  // also callable directly (the tests and the keyboard have no pull)
  const refresh = useCallback(async () => {
    if (refreshing.current) return;
    refreshing.current = true;
    setState({ distance: 0, refreshing: true });
    try { await Promise.all([latest.current?.(), new Promise((r) => setTimeout(r, 600))]); }
    finally { refreshing.current = false; setState({ distance: 0, refreshing: false }); }
  }, []);
  return { ...state, refresh };
}

// The admin top bar shows the page name once the page heading has scrolled away (P9).
export function useScrolledPast(enabled, px = 120) {
  const [past, setPast] = useState(false);
  useEffect(() => {
    if (!enabled) return undefined;
    const on = () => setPast(window.scrollY > px);
    on();
    window.addEventListener("scroll", on, { passive: true });
    return () => window.removeEventListener("scroll", on);
  }, [enabled, px]);
  return past;
}
