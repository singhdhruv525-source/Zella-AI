// Batch 3: the state behind a server-paged list (cursor / keyset paging, sql/zella_batch3_pagination.sql). Pure, so
// it is unit-tested (tests/batch3_unit.test.mjs); crm/paging.js wires it to React and Supabase.
//   cursors[i]   the cursor that loads page i (page 0 has none)
//   seq          the newest request; an answer for an older one (filters changed meanwhile) is dropped
//   data         the last page received for the current filters; kept while a refresh runs or fails ("stale")
export const PAGE_START = { key: null, page: 0, cursors: [null], seq: 0, data: null, error: "", loading: true };

/**
 * Track a zero-based page and its server cursors. Filter changes clear prior data;
 * navigation and reload retain it until a response arrives. Success and failure events
 * must match both the current key and sequence; failures retain the last received data.
 * Next and previous are ignored while loading, and next requires a server cursor.
 */
export function pageReduce(state, event) {
  switch (event.type) {
    case "filters":      // new filters (or another business): back to page 1, nothing from the old list is shown
      return { ...PAGE_START, key: event.key, seq: state.seq + 1 };
    case "request":
      return { ...state, seq: event.seq, loading: true, error: "" };
    case "ok":
      if (event.seq !== state.seq || event.key !== state.key) return state;
      return { ...state, data: event.data, loading: false, error: "" };
    case "fail":
      if (event.seq !== state.seq || event.key !== state.key) return state;
      return { ...state, loading: false, error: event.error || "Couldn't load this list." };
    case "next": {
      const next = state.data?.next;
      if (!next || state.loading) return state;
      const cursors = state.cursors.slice(0, state.page + 1).concat([next]);
      return { ...state, page: state.page + 1, cursors, seq: state.seq + 1 };
    }
    case "prev":
      if (state.page === 0 || state.loading) return state;
      return { ...state, page: state.page - 1, seq: state.seq + 1 };
    case "first":
      return { ...state, page: 0, cursors: [null], seq: state.seq + 1 };
    case "reload":
      return { ...state, seq: state.seq + 1 };
    default:
      return state;
  }
}

/** Return the current page cursor, or null to request the first page. */
export const pageCursor = (state) => state.cursors[state.page] ?? null;
/** Return the last received rows, falling back to an empty list for a missing or non-array payload. */
export const pageRows = (state) => (Array.isArray(state.data?.rows) ? state.data.rows : []);
// "stale": what is shown is from an earlier successful load and the latest load failed
export const pageStatus = (state) => (state.data ? (state.error ? "stale" : "ok") : state.error ? "failed" : "loading");
/** Estimate pages from the server total and page size, with at least one page even before data arrives. */
export const pageCount = (state, size) => Math.max(1, Math.ceil((Number(state.data?.total) || 0) / size));
