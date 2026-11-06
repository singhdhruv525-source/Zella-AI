// Loading, error and stale-data states for the admin dashboard's read-only pages, so a failed request is never shown
// as a real zero or an empty list. A refresh that fails keeps the last good data on screen, labelled as possibly out
// of date, with Retry. Used by Overview, Platform operations, Integrations, AI receptionists, Modules and Businesses.
import { useCallback, useEffect, useRef, useState } from "react";
import { friendlyError } from "./adminOps";
import { loadStatus } from "./loadStatus";

export function useRefreshable(loader) {
  const [state, setState] = useState({ data: null, error: "", loading: true, lastOk: null });
  const attempt = useRef(0);
  const load = useCallback(async () => {
    const mine = ++attempt.current;
    setState((s) => ({ ...s, loading: true }));   // the error stays until a refresh succeeds
    try {
      const data = await loader();
      if (mine === attempt.current) setState({ data: data ?? {}, error: "", loading: false, lastOk: new Date() });
    } catch (err) {
      if (mine === attempt.current) setState((s) => ({ ...s, error: friendlyError(err) || "Something went wrong.", loading: false }));
    }
  }, [loader]);
  useEffect(() => {
    load();
    const attempts = attempt;
    return () => { attempts.current++; };   // a late answer after leaving the page is dropped
  }, [load]);
  return { ...state, status: loadStatus(state), reload: load };
}

const clock = (d) => (d ? d.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" }) : "");

// The error / stale banner under a page heading.
export function LoadNotice({ r, what }) {
  if (r.status === "failed") {
    return (
      <div className="owner-form-error op-gap" role="alert" data-load="failed">
        Could not load {what}: {r.error}{" "}
        <button type="button" className="op-link" onClick={r.reload} disabled={r.loading}>{r.loading ? "Retrying..." : "Retry"}</button>
      </div>
    );
  }
  if (r.status === "stale") {
    return (
      <div className="ic-warning op-gap op-stale" role="status" data-load="stale">
        <span>The latest refresh failed ({r.error}). Showing {what} from {clock(r.lastOk)}; it may be out of date.</span>
        <div><button type="button" className="owner-secondary-button op-small" onClick={r.reload} disabled={r.loading}>{r.loading ? "Retrying..." : "Retry"}</button></div>
      </div>
    );
  }
  return null;
}

// "Updated 10:42" beside the refresh button, once something has loaded.
export function UpdatedAt({ r }) {
  if (!r.lastOk) return null;
  return <span className="op-muted op-updated" data-load-updated>{r.status === "stale" ? "Last updated" : "Updated"} {clock(r.lastOk)}</span>;
}
