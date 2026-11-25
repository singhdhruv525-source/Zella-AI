// Pure helpers for the phone navigation (approved 25 Nov 2026): gesture decisions, the live strip's words, the
// "Needs you now" rows, per tab memory and the undo window. No React and no browser objects, so the node tests can
// run them directly (web/tests/phoneNav.test.mjs).

const MINUTE = 60000;

// "4 min", "1 hr", "2 hr" since a time. Never negative, never "0 min".
export function waitLabel(fromIso, now = Date.now()) {
  const at = new Date(fromIso).getTime();
  if (!Number.isFinite(at)) return "";
  const mins = Math.max(1, Math.floor((now - at) / MINUTE));
  if (mins < 60) return `${mins} min`;
  return `${Math.floor(mins / 60)} hr`;
}

const callers = (n) => (n === 1 ? "1 caller wants a person" : `${n} callers want a person`);

// The CRM live strip: callers waiting for a person (owner decision 6: no "call in progress" strip, that needs live
// call status). oldest = { name, since } for the caller waiting longest, when it could be read.
export function crmStrip(count, oldest, now = Date.now()) {
  if (!(count > 0)) return null;
  const sub = oldest?.name
    ? `${oldest.name}, waiting ${waitLabel(oldest.since, now)}`
    : oldest?.since ? `Waiting ${waitLabel(oldest.since, now)}` : "Your AI receptionist handed them over";
  return { title: callers(count), sub, action: "Open" };
}

// The admin live strip: open platform incidents, the oldest first.
export function adminStrip(incidents = [], now = Date.now()) {
  const open = incidents.filter((i) => i && i.status === "open");
  if (!open.length) return null;
  const oldest = [...open].sort((a, b) => new Date(a.created_at) - new Date(b.created_at))[0];
  const more = open.length > 1 ? ` · ${open.length} open incidents` : "";
  return { title: oldest.title || "Incident open", sub: `Incident open for ${waitLabel(oldest.created_at, now)}${more}`, action: "View" };
}

// "Needs you now" at the top of Today (P14): callers waiting, overdue tasks, calls to review in Spam protection.
// Each row goes straight to the page that deals with it; with nothing to do the section isn't shown (empty list).
// overdueTotal: how many tasks are overdue in all (the list may be cut off at its limit); defaults to the list's length
export function needsNowRows({ waiting = 0, oldest = null, overdue = [], overdueTotal, spam = 0, now = Date.now() } = {}) {
  const rows = [];
  if (waiting > 0) {
    rows.push({
      key: "waiting", icon: "support_agent", tone: "warn", page: "attention", title: callers(waiting),
      sub: oldest?.name ? `${oldest.name}${oldest.summary ? ` asked about ${lower(oldest.summary)}` : ""}` : "Your AI receptionist handed them over",
      meta: oldest?.since ? waitLabel(oldest.since, now) : "",
    });
  }
  const lateCount = Math.max(overdue.length, Number.isFinite(overdueTotal) ? overdueTotal : 0);
  if (lateCount && overdue.length) {
    const t = overdue[0];
    rows.push(lateCount === 1
      ? { key: "overdue", icon: "task_alt", tone: "danger", page: "tasks", title: t.title || "Task", sub: t.who ? `Task for ${t.who}, due ${waitLabel(t.due_at, now)} ago` : `Due ${waitLabel(t.due_at, now)} ago`, meta: "Overdue" }
      : { key: "overdue", icon: "task_alt", tone: "danger", page: "tasks", title: `${lateCount} overdue tasks`, sub: `The oldest: ${t.title || "a task"}`, meta: "Overdue" });
  }
  if (spam > 0) {
    rows.push({ key: "spam", icon: "gpp_maybe", tone: "", page: "spam", title: `${spam === 1 ? "1 call" : `${spam} calls`} to review in Spam protection`, sub: "Blocked as likely spam, check it was right", meta: "" });
  }
  return rows;
}
const lower = (s) => String(s).charAt(0).toLowerCase() + String(s).slice(1);

// ---------- Gestures ----------

// The side panel: a swipe to the left of more than 70px closes it.
export const PANEL_CLOSE_PX = 70;
export const panelDrag = (dx) => Math.min(0, dx);
export const panelReleaseCloses = (dx) => dx < -PANEL_CLOSE_PX;

// A bottom sheet, released after a drag of dy pixels (down is positive). Returns the next size, or "close".
//   half: up 60 opens full, down 90 closes. full: down 260 closes, down 60 goes back to half. fit: down 90 closes.
export function sheetRelease(size, dy) {
  if (size === "fit") return dy > 90 ? "close" : "fit";
  if (size === "half") return dy < -60 ? "full" : dy > 90 ? "close" : "half";
  if (dy > 260) return "close";
  return dy > 60 ? "half" : "full";
}

// A swipe row: the tray of actions is TRAY px wide. Returns where the row rests after a drag (open or closed) and
// how far it may be dragged.
export const rowDrag = (dx, wasOpen, tray) => Math.min(0, Math.max(-tray, dx + (wasOpen ? -tray : 0)));
export const rowReleaseOpens = (offset) => offset < -60;

// Pull to refresh: the pull is damped, and a release past the line refreshes.
export const PULL_REFRESH_PX = 64;
export const pullDistance = (dy) => (dy <= 0 ? 0 : Math.min(96, dy * 0.5));
export const pullReleaseRefreshes = (distance) => distance >= PULL_REFRESH_PX * 0.75;

// The on screen keyboard is open when the visual viewport is much shorter than the layout viewport.
export const keyboardOpen = (innerHeight, viewportHeight) =>
  Number.isFinite(viewportHeight) && Number.isFinite(innerHeight) && innerHeight - viewportHeight > 150;

// ---------- Per tab memory (P16): scroll position and search, kept while the workspace is open ----------
export function createTabMemory() {
  const store = new Map();
  return {
    save(key, patch) { if (key) store.set(key, { ...(store.get(key) ?? {}), ...patch }); },
    read(key) { return store.get(key) ?? {}; },
    clear() { store.clear(); },
  };
}

// ---------- The undo window (P19) ----------
// A quick change shows at once and is only sent once the Undo window has passed, so Undo never needs a reverse call
// on the server: it simply never sends. If sending fails, revert() puts it back and the caller says so.
//   apply()   show the change now        commit()  send it (returns a promise; rejects or { error } on failure)
//   revert()  put it back                ms        the Undo window
// Returns { undo, flush }: undo() within the window cancels; flush() sends now (leaving the page).
// (the browser's timers must be called as plain functions, never as methods of another object)
const TIMERS = { setTimeout: (fn, ms) => setTimeout(fn, ms), clearTimeout: (t) => clearTimeout(t) };
export function deferChange({ apply, commit, revert, onError, ms = 5000, timers = TIMERS }) {
  let state = "waiting";
  apply?.();
  const send = async () => {
    if (state !== "waiting") return;
    state = "sent";
    try {
      const result = await commit();
      if (result && result.error) throw result.error;
    } catch (err) {
      revert?.();
      onError?.(err);
    }
  };
  const timer = timers.setTimeout(send, ms);
  return {
    undo() {
      if (state !== "waiting") return false;
      state = "undone";
      timers.clearTimeout(timer);
      revert?.();
      return true;
    },
    flush() { timers.clearTimeout(timer); return send(); },
    get state() { return state; },
  };
}
