// B3-01: how many callers are waiting for a person, as a state rather than a bare number, so a failed check is never
// shown as "nobody is waiting". Pure (no React, no network) so it is unit-tested in tests/batch3_unit.test.mjs.
//   loading      first check still running; nothing is claimed
//   ok           the count from the latest check (0 is a real 0)
//   stale        the latest check failed; the last known count is kept and marked as possibly out of date
//   unavailable  no check has ever succeeded for this business; no count is shown
export const ATTENTION_START = { status: "loading", count: null, checkedAt: null, businessId: null };

export function attentionReduce(state, event) {
  // a result for another business (a switch while a check was in flight) is dropped
  if (event.type !== "reset" && event.businessId !== undefined && state.businessId !== null && event.businessId !== state.businessId) return state;
  switch (event.type) {
    case "reset":
      return { ...ATTENTION_START, businessId: event.businessId ?? null };
    case "ok": {
      const n = Number.isInteger(event.count) && event.count >= 0 ? event.count : null;
      if (n === null) return attentionReduce(state, { type: "fail" });   // a malformed answer is a failed check
      return { ...state, status: "ok", count: n, checkedAt: event.at ?? new Date() };
    }
    case "fail":
      return state.count === null ? { ...state, status: "unavailable" } : { ...state, status: "stale" };
    default:
      return state;
  }
}

// the number for the sidebar badge and the banner: only a count that was actually received
export const attentionCount = (s) => (s.status === "ok" || s.status === "stale") && Number.isInteger(s.count) ? s.count : 0;
// whether to show the "couldn't check" notice
export const attentionWarning = (s) => s.status === "stale" || s.status === "unavailable";
