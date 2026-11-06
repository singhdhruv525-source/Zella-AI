// Pure helpers behind admin/loadState.jsx: which state a page's data is in, and what a metric or empty list may say.
// Kept apart from the components so they can be unit-tested (web/tests/batch2_unit.test.mjs).
// status: "loading" (nothing yet) | "failed" (nothing loaded; the last attempt failed) | "ok" | "stale" (data from an
// earlier success; the latest refresh failed)
export function loadStatus({ data, error, loading }) {
  if (data != null) return error ? "stale" : "ok";
  if (error) return "failed";
  return loading ? "loading" : "failed";
}

// A metric's text: "…" while loading, "—" when there is no trustworthy number (nothing loaded, or the value is missing
// from the answer), otherwise the number itself, zero included.
export const isCount = (v) => typeof v === "number" && Number.isFinite(v);
export function metric(value, r) {
  if (r.status === "loading") return "…";
  if (r.status === "failed") return "—";
  return isCount(value) ? value : "—";
}
// The count of an array in the answer, or null when the array isn't there.
export const countOf = (list, filter) => (Array.isArray(list) ? (filter ? list.filter(filter).length : list.length) : null);

// What an empty list says: only "nothing here" after a successful load.
export function emptyText(r, whenEmpty, what = "this list") {
  if (r.status === "loading") return "Loading...";
  if (r.status === "failed") return `Not available: ${what} couldn't be loaded.`;
  return whenEmpty;
}

