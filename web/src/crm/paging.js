import { useCallback, useEffect, useReducer, useRef, useState } from "react";
import { supabase } from "../supabase";
import { friendly } from "../BusinessShared";
import { PAGE_START, pageCount, pageCursor, pageReduce, pageRows, pageStatus } from "./pagingState";

// A list paged by the server (Batch 3). `fn` is one of the zella_*_page functions; `args` are its filters. Changing a
// filter starts again from page 1; only the newest request may change what is shown (fast filter changes can't let
// an older answer win); a failed refresh keeps the rows it had and says so (status "stale").
/**
 * Fetch a zella_*_page RPC using filters in args, overriding p_limit and p_after.
 * Changes to the serialized function, filters, or page size reset paging. Returns
 * rows, the raw response, totals, a zero-based page, request state, and navigation controls.
 * RPC errors and rejected requests become a displayable error; previously received
 * data is retained and marked stale on failure. Initial failures have status "failed".
 */
export function useServerPages(fn, args, pageSize) {
  const key = JSON.stringify([fn, args, pageSize]);
  const [state, dispatch] = useReducer(pageReduce, { ...PAGE_START, key });
  const latest = useRef(state);
  latest.current = state;

  useEffect(() => { if (latest.current.key !== key) dispatch({ type: "filters", key }); }, [key]);

  useEffect(() => {
    if (state.key !== key) return undefined;
    let live = true;
    const seq = state.seq;
    dispatch({ type: "request", seq });
    supabase.rpc(fn, { ...args, p_limit: pageSize, p_after: pageCursor(state) })
      .then(({ data, error }) => {
        if (!live) return;
        if (error) dispatch({ type: "fail", seq, key, error: friendly(error) });
        else dispatch({ type: "ok", seq, key, data });
      })
      .catch((err) => { if (live) dispatch({ type: "fail", seq, key, error: friendly(err) }); });
    return () => { live = false; };
    // the request depends only on the key (filters) and the page's cursor, both captured in state.seq
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [state.seq, state.key, key]);

  return {
    rows: pageRows(state),
    data: state.data,
    total: Number(state.data?.total) || 0,
    page: state.page,
    pages: pageCount(state, pageSize),
    hasNext: Boolean(state.data?.next),
    loading: state.loading,
    error: state.error,
    status: pageStatus(state),
    next: useCallback(() => dispatch({ type: "next" }), []),
    prev: useCallback(() => dispatch({ type: "prev" }), []),
    first: useCallback(() => dispatch({ type: "first" }), []),
    reload: useCallback(() => dispatch({ type: "reload" }), []),
  };
}

// a value that settles: the search box asks the server once typing pauses, not on every key
/**
 * Return the initial value immediately, then publish changes after ms milliseconds
 * without another value or delay change. Pending updates are canceled on unmount.
 */
export function useSettled(value, ms = 300) {
  const [settled, setSettled] = useState(value);
  useEffect(() => {
    const t = setTimeout(() => setSettled(value), ms);
    return () => clearTimeout(t);
  }, [value, ms]);
  return settled;
}
