// The reads behind "Needs you now" (Today and the notification bell), as pure functions so they can be tested.
// Each source (waiting callers, overdue tasks, spam to review) keeps whether its last read worked
// (navigation/phoneHelpers.js signalReduce): a failed read keeps the last good value, marked as possibly out of date,
// and is never shown as "nothing waiting". A list counts as complete (so the bell may mark a server notification
// about something missing from it as read) only when the latest read worked and proves it holds every row.
import { SIGNAL_START, signalReduce } from "../navigation/phoneHelpers.js";

export const WAITING_CAP = 500;     // callers past it share one summary note in the bell
export const OVERDUE_LIMIT = 100;   // tasks past it share one summary note in the bell

export const SOURCES_START = { waiting: SIGNAL_START, overdue: SIGNAL_START, spam: SIGNAL_START };

// A list read in ONE request with an exact count: the rows and the count come from the same moment, so a call that
// is dealt with (or a new one) between two page requests can never make a short list look complete. It is complete
// only when it holds as many rows as the count says exist.
//   res: { data, count, error } from the read; returns the event for signalReduce
export function listRead(res) {
  if (!res || res.error || !Array.isArray(res.data)) return { type: "fail" };
  const rows = res.data;
  const total = Number.isFinite(res.count) ? Math.max(res.count, rows.length) : null;
  return {
    type: "ok",
    value: { rows, total: total ?? rows.length, more: total === null ? 0 : total - rows.length, complete: total !== null && rows.length === total },
  };
}

// The spam overview: a count to review, or nothing for a role that may not see it (that is a real "none").
export function spamRead(res, allowed = true) {
  if (!allowed) return { type: "ok", value: 0 };
  if (!res || res.error || !res.data) return { type: "fail" };
  const n = countValue(res.data.unreviewed);
  return n === null ? { type: "fail" } : { type: "ok", value: n };
}

// A count from a server answer: a finite number of zero or more, or a string holding one ("3"). Anything else
// (missing, null, "", true, "a few", NaN, negative) is not a count, and the read counts as failed, never as 0.
export function countValue(v) {
  if (typeof v === "number") return Number.isFinite(v) && v >= 0 ? v : null;
  if (typeof v === "string" && /^\s*\d+(\.\d+)?\s*$/.test(v)) {
    const n = Number(v);
    return Number.isFinite(n) ? n : null;   // a string of hundreds of digits overflows to Infinity: not a count
  }
  return null;
}

// The next state of all three sources after one round of reads.
export function nextSources(prev = SOURCES_START, events = {}) {
  return {
    waiting: events.waiting ? signalReduce(prev.waiting, events.waiting) : prev.waiting,
    overdue: events.overdue ? signalReduce(prev.overdue, events.overdue) : prev.overdue,
    spam: events.spam ? signalReduce(prev.spam, events.spam) : prev.spam,
  };
}

const usable = (s) => s.status === "ok" || s.status === "stale";

// What Today and the bell read: the last good values, whether each list is proven complete by the latest read, and
// whether anything couldn't be checked.
export function signalsFrom(sources = SOURCES_START, at = null) {
  const w = usable(sources.waiting) ? sources.waiting.value : null;
  const o = usable(sources.overdue) ? sources.overdue.value : null;
  const waiting = w?.rows ?? [];
  const overdue = o?.rows ?? [];
  const statuses = [sources.waiting.status, sources.overdue.status, sources.spam.status];
  return {
    oldest: waiting[0] ?? null,
    waiting,
    waitingMore: w?.more ?? 0,
    overdue,
    overdueTotal: o?.total ?? overdue.length,
    overdueMore: o?.more ?? 0,
    spam: usable(sources.spam) ? sources.spam.value ?? 0 : 0,
    // only a list the latest read worked for, and proved complete, can show that something has been dealt with
    complete: {
      waiting: sources.waiting.status === "ok" && Boolean(w?.complete),
      task: sources.overdue.status === "ok" && Boolean(o?.complete),
    },
    status: { waiting: sources.waiting.status, overdue: sources.overdue.status, spam: sources.spam.status },
    ready: statuses.every((s) => s === "ok"),          // every source read now: read keys may be pruned
    loading: statuses.some((s) => s === "loading"),    // a source hasn't read yet: nothing can be called quiet
    unavailable: statuses.some((s) => s === "failed" || s === "stale"),
    at,
  };
}
