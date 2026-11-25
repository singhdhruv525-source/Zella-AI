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

// ---------- A live reading that can fail (admin counts and incidents) ----------
// loading: not read yet. ok: the last read worked. stale: an earlier read worked, the latest failed (the value is the
// earlier one, shown as possibly out of date). failed: no read has worked yet (no value: never shown as "none").
export const SIGNAL_START = { status: "loading", value: null };
export function signalReduce(state = SIGNAL_START, event = {}) {
  if (event.type === "reset") return SIGNAL_START;
  if (event.type === "ok") return { status: "ok", value: event.value };
  if (event.type === "fail") return state.status === "ok" || state.status === "stale" ? { status: "stale", value: state.value } : { status: "failed", value: null };
  return state;
}
// A count from such a reading, for a tab: the number only when it was read (stale says so), never 0 for a failure.
export function signalCount(state) {
  if (state?.status === "ok" || state?.status === "stale") return { count: state.value, state: state.status };
  return { count: null, state: state?.status ?? "loading" };
}
// The admin live strip from the incidents reading: open incidents as usual; a failed read says so instead of
// looking calm; an out of date read says that too.
export function adminStripFor(state, now = Date.now()) {
  if (!state || state.status === "loading") return null;
  if (state.status === "failed") return { title: "Incidents couldn't be checked", sub: "Open Platform operations for the latest", action: "View" };
  const strip = adminStrip(state.value ?? [], now);
  if (state.status === "ok") return strip;
  return strip ? { ...strip, sub: `${strip.sub} · may be out of date` } : { title: "Incidents couldn't be refreshed", sub: "Open Platform operations for the latest", action: "View" };
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
// Several quick changes can wait at once; one toast offers Undo for all of them (undoAll), so none loses its Undo.
// (the browser's timers must be called as plain functions, never as methods of another object)
const TIMERS = { setTimeout: (fn, ms) => setTimeout(fn, ms), clearTimeout: (t) => clearTimeout(t) };
//   beacon()  optional: sends the change in a way that survives the tab closing (fetch keepalive); returns true when
//             it could start the send. Used only when the page is going away (unload()).
//   beaconReady()  optional, no side effects: whether beacon() could send right now (config, a current access token,
//             fetch). A change whose beacon isn't ready counts as one the browser must ask about before closing.
export function deferChange({ apply, commit, revert, onError, beacon, beaconReady, ms = 5000, timers = TIMERS }) {
  let state = "waiting";
  let sending = null;   // the send in progress: a later flush() returns it, so signing out waits for it
  apply?.();
  const send = () => {
    if (state === "sent") return sending ?? Promise.resolve();
    if (state !== "waiting") return Promise.resolve();   // undone: nothing to send
    state = "sent";
    sending = (async () => {
      try {
        const result = await commit();
        if (result && result.error) throw result.error;
      } catch (err) {
        revert?.();
        onError?.(err);
      }
    })();
    return sending;
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
    // the page is closing (pagehide): a request the browser keeps alive when it can, else the usual send
    unload() {
      if (state !== "waiting") return false;
      timers.clearTimeout(timer);
      if (beacon && beacon()) { state = "sent"; sending = Promise.resolve(); return true; }
      send();
      return false;
    },
    get canBeacon() { return Boolean(beacon) && (beaconReady ? Boolean(beaconReady()) : true); },
    get state() { return state; },
  };
}

// Undo every change still inside its window; returns how many were undone (one already sent is left alone).
export function undoAll(changes) {
  let n = 0;
  for (const c of changes) if (c?.undo?.()) n++;
  return n;
}
// The toast for the latest quick change: its own words, or a count while others are still waiting.
export const pendingToastText = (text, waiting) => (waiting > 1 ? `${waiting} changes made` : text);

// ---------- Quick changes that outlive the page (P19) ----------
// The app keeps the changes waiting for their Undo window, so leaving the page neither sends them early nor loses
// their Undo; each one is sent by its own timer (or when the page is closed, pagehide). For every change the store
// keeps what the page shows meanwhile (its view: hidden, or the new values); after a successful send the view stays
// "settled" until the page has read the list again, so the row never flickers back.
export function createPendingStore() {
  const pending = new Map();   // id -> { change, view }
  const settled = new Map();   // id -> view
  const subs = new Set();
  const emit = (event) => subs.forEach((f) => f(event));
  return {
    has: (id) => pending.has(id),
    change: (id) => pending.get(id)?.change ?? null,
    add(id, change, view) { pending.set(id, { change, view }); emit({ type: "add", id }); },
    // sent: the page reads its list again, then calls clearSettled(id)
    succeed(id) { const e = pending.get(id); pending.delete(id); if (e) settled.set(id, e.view); emit({ type: "sent", id }); },
    // undone, or the send failed: the view goes, the row is back as it was
    drop(id) { if (pending.delete(id)) emit({ type: "drop", id }); },
    clearSettled(id) { if (settled.delete(id)) emit({ type: "settled", id }); },
    // a page that has just read its list fresh: what was sent is in it now
    clearAllSettled() { if (settled.size) { settled.clear(); emit({ type: "settled" }); } },
    views() { return new Map([...settled, ...[...pending].map(([id, e]) => [id, e.view])]); },
    changes() { return [...pending.values()].map((e) => e.change); },
    waiting() { return [...pending.values()].filter((e) => e.change.state === "waiting").length; },
    subscribe(f) { subs.add(f); return () => subs.delete(f); },
    flushAll() { return Promise.all([...pending.values()].map((e) => e.change.flush())); },
    // the tab is closing: each waiting change goes out as a keepalive request where it can
    unloadAll() { [...pending.values()].forEach((e) => e.change.unload?.()); },
    // changes still waiting that can't be sent that way (the browser is asked to confirm leaving while there are any)
    waitingWithoutBeacon() { return [...pending.values()].filter((e) => e.change.state === "waiting" && !e.change.canBeacon).length; },
  };
}

// The request for a change sent while the tab closes (fetch with keepalive: true, so the browser lets it finish):
// the same endpoint and headers the Supabase client uses. Pure: the caller supplies the address, the publishable key
// and the signed in person's access token; returns null without a token (then the change can't go this way).
//   kind "rpc": a database function (/rest/v1/rpc/<name>); kind "function": an edge function (/functions/v1/<name>)
export function keepaliveRequest({ url, key, token }, kind, name, body) {
  if (!url || !key || !token || !name) return null;
  const path = kind === "rpc" ? `/rest/v1/rpc/${encodeURIComponent(name)}` : kind === "function" ? `/functions/v1/${encodeURIComponent(name)}` : null;
  if (!path) return null;
  return {
    url: `${url}${path}`,
    init: {
      method: "POST", keepalive: true,
      headers: { "Content-Type": "application/json", apikey: key, Authorization: `Bearer ${token}` },
      body: JSON.stringify(body ?? {}),
    },
  };
}
