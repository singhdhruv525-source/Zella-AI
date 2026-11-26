// "Needs you now" in the notification bell (owner, 25 Nov 2026): every item Today's "Needs you now" shows is also in
// the CRM bell, on phones and desktops, and opens the same page. Built in the app from the data "Needs you now"
// already reads (navigation/CrmPhone.jsx useCrmSignals), never written to staff_notifications: rows there are picked
// up for email, text and push delivery, and these stay in the app only.
//
// One note per item, keyed by what it is about (the call, the task); it leaves the bell as soon as the item is dealt
// with, so the bell always matches "Needs you now". Read state is kept on this device per business. A server
// notification about the same call or task (escalation_unacknowledged, task_overdue) is not shown twice: the note
// here takes its place, and once that call or task is dealt with the server one is marked read.
import { waitLabel } from "../navigation/phoneHelpers.js";

// Server notification kinds that are about the same thing as a note here, and which note group covers them.
export const COVERED_KINDS = { escalation_unacknowledged: "waiting", task_overdue: "task" };

const lower = (s) => String(s).charAt(0).toLowerCase() + String(s).slice(1);

/**
 * The bell notes for "Needs you now".
 *   waiting: calls waiting for a person [{ id, name, summary, since }]
 *   waitingMore: callers waiting beyond the ones listed (the list has a hard cap): one summary note for them
 *   overdue: open tasks past their due time [{ id, title, who, due_at }]
 *   overdueMore: overdue tasks beyond the ones listed (the list has a limit): one summary note for them
 *   spam:    calls to review in Spam protection (a count)
 *   at:      when the signals were read (the time shown on the spam note)
 */
export function needsNowNotes({ waiting = [], waitingMore = 0, overdue = [], overdueMore = 0, spam = 0, at = null, now = Date.now() } = {}) {
  const notes = [];
  for (const c of waiting) {
    if (!c?.id) continue;
    notes.push({
      key: `waiting:${c.id}`, group: "waiting", entity_id: c.id, derived: true, kind: "needs_you_now", icon: "support_agent", severity: "urgent",
      title: c.name ? `${c.name} wants a person` : "A caller wants a person",
      body: c.summary ? `Asked about ${lower(c.summary)}. Waiting ${waitLabel(c.since, now)}` : `Your AI receptionist handed them over. Waiting ${waitLabel(c.since, now)}`,
      page_key: "attention", created_at: c.since ?? null,
    });
  }
  if (waitingMore > 0) {
    // every waiting caller is in the bell: the ones past the cap share one note, keyed by how many there are
    notes.push({
      key: `waiting-more:${waitingMore}`, group: "waiting-more", entity_id: null, derived: true, kind: "needs_you_now", icon: "support_agent", severity: "urgent",
      title: waitingMore === 1 ? "And 1 more caller wants a person" : `And ${waitingMore} more callers want a person`,
      body: "Open Needs attention to see them all", page_key: "attention", created_at: at,
    });
  }
  for (const t of overdue) {
    if (!t?.id) continue;
    notes.push({
      key: `task:${t.id}`, group: "task", entity_id: t.id, derived: true, kind: "needs_you_now", icon: "task_alt", severity: "warning",
      title: `Overdue: ${t.title || "a task"}`,
      body: t.who ? `Task for ${t.who}, due ${waitLabel(t.due_at, now)} ago` : `Due ${waitLabel(t.due_at, now)} ago`,
      page_key: "tasks", created_at: t.due_at ?? null,
    });
  }
  if (overdueMore > 0) {
    notes.push({
      key: `task-more:${overdueMore}`, group: "task-more", entity_id: null, derived: true, kind: "needs_you_now", icon: "task_alt", severity: "warning",
      title: overdueMore === 1 ? "And 1 more overdue task" : `And ${overdueMore} more overdue tasks`,
      body: "Open Tasks to see them all", page_key: "tasks", created_at: at,
    });
  }
  if (spam > 0) {
    // one note for the count; a higher count is a new note (the earlier one was about fewer calls)
    notes.push({
      key: `spam:${spam}`, group: "spam", entity_id: null, derived: true, kind: "needs_you_now", icon: "gpp_maybe", severity: "info",
      title: `${spam === 1 ? "1 call" : `${spam} calls`} to review in Spam protection`, body: "Blocked as likely spam, check it was right",
      page_key: "spam", created_at: at,
    });
  }
  return notes;
}

/**
 * The bell's list: server notifications and the notes above, without duplicates.
 *   server:   staff_notifications rows (newest first)
 *   notes:    needsNowNotes(...)
 *   read:     Set of note keys read on this device
 *   complete: { waiting, task } true when that list was read in full (not cut off by its limit), so a server
 *             notification about something missing from it is known to be dealt with
 *   at:       when that list was read. Only a server notification older than that read is cleared: one written
 *             after it may be about an item the read hasn't seen yet
 * Returns { rows, unread, stale }: rows (the notes first, then the rest newest first; each note has read_at set when
 * read here), the unread count, and the ids of unread server notifications to mark read because what they were about
 * is dealt with (those, read or not, are no longer in rows).
 */
export function mergeBellNotes(server = [], notes = [], read = new Set(), complete = {}, at = null) {
  const readAt = new Date(at ?? NaN).getTime();
  const active = { waiting: new Set(), task: new Set() };
  for (const n of notes) if (active[n.group] && n.entity_id) active[n.group].add(n.entity_id);
  const stale = [];
  const kept = server.filter((r) => {
    const group = COVERED_KINDS[r.kind];
    if (!group || !r.entity_id) return true;
    if (active[group].has(r.entity_id)) return false;              // the note here takes its place
    const created = new Date(r.created_at ?? NaN).getTime();
    // dealt with, proven by a complete read newer than the notification: it leaves the bell, as the note did (an
    // unread one is also marked read on the server)
    if (complete[group] && Number.isFinite(readAt) && Number.isFinite(created) && created < readAt) {
      if (!r.read_at) stale.push(r.id);
      return false;
    }
    return true;   // not proven dealt with: kept as it is
  });
  const shown = notes.map((n) => ({ ...n, id: n.key, read_at: read.has(n.key) ? "read" : null }));
  const time = (r) => { const t = new Date(r.created_at ?? 0).getTime(); return Number.isFinite(t) ? t : 0; };
  const rows = [...shown, ...kept]
    // the notes first, in the order Today lists them (callers, tasks, spam); then the rest, newest first
    .sort((a, b) => (b.derived ? 1 : 0) - (a.derived ? 1 : 0) || (a.derived ? 0 : time(b) - time(a)));
  return { rows, unread: rows.filter((r) => !r.read_at).length, stale };
}

// Read keys for notes that have left the bell are dropped, so a list kept on the device never grows.
//   complete: { waiting, task } from the signals: a key is only forgotten when its list was read in full (a task past
//   the overdue limit, left out of the list, is not dealt with). Spam and the summary notes follow their list.
const KEY_GROUP = { waiting: "waiting", "waiting-more": "waiting", task: "task", "task-more": "task", spam: "spam" };
export function pruneRead(read, notes, complete = { waiting: true, task: true, spam: true }) {
  const live = new Set(notes.map((n) => n.key));
  return new Set([...read].filter((k) => {
    if (live.has(k)) return true;
    const group = KEY_GROUP[String(k).split(":")[0]];
    return group ? !complete[group] : false;   // an incomplete list proves nothing: the key stays
  }));
}

const READ_KEY = (businessId) => `zella.needsNow.read.${businessId}`;
export function loadRead(businessId) {
  try { return new Set(JSON.parse(localStorage.getItem(READ_KEY(businessId)) ?? "[]")); } catch { return new Set(); }
}
export function saveRead(businessId, set) {
  try { localStorage.setItem(READ_KEY(businessId), JSON.stringify([...set])); } catch { /* private mode: read for this visit only */ }
}
