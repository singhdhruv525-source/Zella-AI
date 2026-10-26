import { useEffect, useState } from "react";

// Tiny address-bar router for the admin dashboard and the business app.
// The page lives in the URL, so refresh keeps it, Back and Forward work, and a
// link can open a page directly. The host must send every path to index.html
// (the reschedule, unsubscribe and /app links already rely on that).

const EVENT = "zella:navigate";

export function navigate(to, { replace = false } = {}) {
  if (to === window.location.pathname + window.location.search) return;
  window.history[replace ? "replaceState" : "pushState"](null, "", to);
  window.dispatchEvent(new Event(EVENT));
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
