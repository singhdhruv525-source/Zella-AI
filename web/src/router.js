import { useEffect, useState } from "react";

// Tiny address-bar router for the admin dashboard and the business app.
// The page lives in the URL, so refresh keeps it, Back and Forward work, and a
// link can open a page directly. The host must send every path to index.html
// (the reschedule, unsubscribe and /app links already rely on that).

const EVENT = "zella:navigate";
const LEAVE_MESSAGE = "You have unsaved changes. Leave this page and lose them?";

// Forms with unsaved changes register a check; every navigation asks first.
const guards = new Set();
let shownPath = typeof window === "undefined" ? "/" : window.location.pathname + window.location.search;

// Returns the function that removes the check (call it when the form goes away).
export function addLeaveGuard(isDirty) {
  guards.add(isDirty);
  return () => guards.delete(isDirty);
}

const hasUnsaved = () => [...guards].some((g) => g());
const mayLeave = () => !hasUnsaved() || window.confirm(LEAVE_MESSAGE);

export function navigate(to, { replace = false, force = false } = {}) {
  if (to === window.location.pathname + window.location.search) return;
  if (!force && !mayLeave()) return;
  window.history[replace ? "replaceState" : "pushState"](null, "", to);
  shownPath = to;
  window.dispatchEvent(new Event(EVENT));
}

if (typeof window !== "undefined") {
  // Back/Forward cannot be cancelled, so put the address back if the person stays.
  window.addEventListener("popstate", (event) => {
    const next = window.location.pathname + window.location.search;
    if (hasUnsaved() && !window.confirm(LEAVE_MESSAGE)) {
      window.history.pushState(null, "", shownPath);
      event.stopImmediatePropagation();
      return;
    }
    shownPath = next;
  }, true);
  // Closing the tab or reloading with unsaved changes: the browser asks.
  window.addEventListener("beforeunload", (event) => {
    if (hasUnsaved()) {
      event.preventDefault();
      event.returnValue = "";
    }
  });
}

// The current path, updated on navigate() and on Back/Forward.
export function usePath() {
  const [path, setPath] = useState(window.location.pathname);
  useEffect(() => {
    const update = () => setPath(window.location.pathname);
    window.addEventListener("popstate", update);
    window.addEventListener(EVENT, update);
    return () => {
      window.removeEventListener("popstate", update);
      window.removeEventListener(EVENT, update);
    };
  }, []);
  return path;
}

// "/app/settings/team/" -> ["app", "settings", "team"]
export const segments = (path) => path.split("/").filter(Boolean).map(decodeURIComponent);
