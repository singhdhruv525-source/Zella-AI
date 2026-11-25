import { useCallback, useEffect, useRef, useState } from "react";
import { Icon } from "./BusinessUI";
import "./OwnerPages.css";
import "./SupportTickets.css";
import { callOwnerFunction } from "./CreateBusinessWizard";
import { Pill } from "./OwnerOverview";
import { formatDateTime, timeAgo } from "./ownerFormat";
import { friendlyError } from "./admin/adminOps";
import { businessHoursText } from "./adminAccess";
import { usePhoneUi } from "./navigation/phoneContext";
import { Skeleton, SwipeRow, usePendingViews } from "./navigation/PhoneNav";
import { BottomSheet } from "./navigation/BottomSheet";
import { createPendingStore, deferChange, panelReplacesPending, pendingToastText, undoAll } from "./navigation/phoneHelpers";
import { keepaliveReady, sendKeepalive } from "./navigation/keepalive";

const STATUSES = [["open", "Open"], ["in_progress", "In progress"], ["resolved", "Resolved"], ["closed", "Closed"]];
const PRIORITIES = [["low", "Low"], ["normal", "Normal"], ["high", "High"], ["urgent", "Urgent"]];
const STATUS_TONE = { open: "warning", in_progress: "info", resolved: "success", closed: "neutral" };
const PRIORITY_TONE = { low: "neutral", normal: "neutral", high: "warning", urgent: "danger" };
const label = (pairs, key) => pairs.find(([k]) => k === key)?.[1] ?? key;
// categories are stored as typed ("technical", "billing"); show them with a capital ("Technical", "Billing")
const categoryText = (c) => {
  const t = String(c ?? "").replace(/_/g, " ").trim();
  return t ? t.charAt(0).toUpperCase() + t.slice(1) : "";
};
// "First reply: within a business hour." / "First reply: after 2.5 business hours."
const firstReplyText = (h) => (Number.isFinite(h) && h < 1 ? "First reply: within a business hour." : `First reply: after ${businessHoursText(h)}.`);

const EMPTY_TICKET = { businessId: "", subject: "", description: "", category: "", priority: "normal" };

export default function SupportTickets({ onOpenBusiness, myEmail }) {
  // On a phone the list is rows you can swipe (approved 25 Nov 2026, P19 and P20): Assign to yourself or Resolve, shown
  // at once with Undo, and only sent once the Undo window has passed (navigation/phoneHelpers.js deferChange).
  const ui = usePhoneUi();
  // the app keeps the waiting changes (navigation/PhoneNav.jsx usePendingStore), so leaving Support neither sends them
  // early nor loses their Undo; outside the app (no store given) the page keeps its own
  const [ownStore] = useState(createPendingStore);
  const store = ui.pending ?? ownStore;
  const [rowMenu, setRowMenu] = useState(null);
  useEffect(() => (store === ownStore ? () => { ownStore.flushAll(); } : undefined), [store, ownStore]);
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [statusFilter, setStatusFilter] = useState("active");
  const [selectedId, setSelectedId] = useState(null);
  const [creating, setCreating] = useState(false);
  const [draft, setDraft] = useState(EMPTY_TICKET);
  const [note, setNote] = useState("");
  const [reply, setReply] = useState("");
  // drafts belong to one ticket: switching tickets (or closing) starts fresh ones
  // a ticket just created, opened as soon as a regular list holding it arrives (the overdue tab never holds it)
  const [openWhenListed, setOpenWhenListed] = useState(null);
  const selectTicket = (id) => { setSelectedId(id); setNote(""); setReply(""); setOpenWhenListed(null); };

  // only the latest load may show its result, so an older refresh can't replace the list read after a reply
  const request = useRef(0);
  // Waiting too long asks the server for the overdue tickets themselves (every waiting ticket is judged there), not
  // a filter of the newest tickets loaded for the other tabs
  const overdueTab = statusFilter === "overdue";
  // resolves true only when this read put fresh tickets on screen (a failed or overtaken read resolves false)
  const load = useCallback(async () => {
    const mine = ++request.current;
    // quick changes already settled when this read starts: once it puts fresh tickets on screen they are in it, so
    // their shown values give way (any read that works, not only the one after the send; never a change settled later)
    const settledBefore = store.settledSnapshot();
    setLoading(true);
    setError("");
    try {
      const next = await callOwnerFunction("tickets_list", overdueTab ? { overdue: true } : {});
      if (mine !== request.current) return false;
      setData({ ...next, overdueOnly: overdueTab });
      store.clearSettledSnapshot(settledBefore);
      return true;
    } catch (err) {
      if (mine === request.current) setError(friendlyError(err));
      return false;
    } finally {
      if (mine === request.current) setLoading(false);
    }
  }, [overdueTab, store]);

  useEffect(() => {
    load();
  }, [load]);
  // a refresh after a change uses the tab shown when it finishes, not the one shown when the change was sent
  const loadRef = useRef(load);
  const overdueRef = useRef(overdueTab);
  useEffect(() => { loadRef.current = load; overdueRef.current = overdueTab; }, [load, overdueTab]);
  // a quick change sent while this page is open: read the list again, then its shown values give way to the real ones
  // (load clears the settled values itself, only after a read that worked: a failed read keeps them)
  const pendingViews = usePendingViews(store, () => { loadRef.current(); });
  // Opened when a successful regular list holding it arrives. Switching to Waiting too long while the refresh after
  // creating is still running sends the page back once; after that refresh (or if it fails) tabs switch freely.
  const createRefresh = useRef(false);
  useEffect(() => {
    if (!openWhenListed) return;
    if (overdueTab && createRefresh.current) { createRefresh.current = false; setStatusFilter("active"); return; }
    if (!loading && data && data.overdueOnly === false && (data.tickets ?? []).some((t) => t.id === openWhenListed)) {
      setSelectedId(openWhenListed);
      setOpenWhenListed(null);
    }
  }, [openWhenListed, overdueTab, loading, data]);
  // reply times are known only once the server says conversations are available (sql/zella_support_replies.sql)
  const timesKnown = data?.conversations === true;

  // the list shown is only ever the answer for this kind of tab (overdue only, or the regular list); until that answer
  // arrives the table says loading or the error, never "No tickets here"
  const listMatches = Boolean(data) && data.overdueOnly === overdueTab;
  // an empty list is "No tickets here" only when the latest read for this tab succeeded and nothing is loading
  const emptyIsCurrent = listMatches && !loading && !error;
  // without reply times (sql/zella_support_replies.sql not applied) the server can't tell which tickets are overdue
  const overdueUnknown = overdueTab && listMatches && !timesKnown;
  const tickets = (listMatches && !overdueUnknown ? data.tickets ?? [] : []).map((t) => (pendingViews.get(t.id) ? { ...t, ...pendingViews.get(t.id) } : t)).filter((t) =>
    statusFilter === "all" ? true : statusFilter === "overdue" ? t.overdue === true : statusFilter === "active" ? ["open", "in_progress"].includes(t.status) : t.status === statusFilter
  );
  const selected = data?.tickets?.find((t) => t.id === selectedId) ?? null;
  // with the detail panel open the table is narrow: Business moves into each row's second line and Assigned is in the panel
  const detailOpen = Boolean(selected || creating);

  async function update(payload) {
    // the admin's last explicit choice wins: a quick change still waiting for this ticket is called off when this sets
    // the same field (a status or an assignee); a note or a reply leaves it to go ahead
    if (store.has(selectedId) && panelReplacesPending(store.views().get(selectedId), payload)) store.change(selectedId)?.undo();
    setBusy(true);
    setError("");
    try {
      const r = await callOwnerFunction("ticket_update", { ticketId: selectedId, ...payload });
      // clear only the text that was sent; anything typed since stays
      if (payload.note) setNote((current) => (current === payload.note ? "" : current));
      // the other changes were saved but the reply wasn't: say so, and keep the reply to send again on its own
      if (r?.replyFailed) setError(`The other changes were saved, but the reply wasn't sent: ${r.replyFailed}`);
      else if (payload.reply) setReply((current) => (current === payload.reply ? "" : current));
      await loadRef.current();
    } catch (err) {
      setError(friendlyError(err));
    } finally {
      setBusy(false);
    }
  }

  // The signed in admin in the list of people a ticket can be assigned to.
  const me = (data?.assignees ?? []).find((a) => a.email && myEmail && a.email.toLowerCase() === myEmail.toLowerCase()) ?? null;
  function quickChange(t, kind) {
    // one quick change per ticket at a time (the others are disabled while it waits); never a silent drop
    if (store.has(t.id)) { ui.toast("A change to this ticket is still being saved. Try again in a moment."); return; }
    const resolve = kind === "resolve";
    const shown = resolve ? { status: "resolved" } : { assigned_to: me.id, assignee: me.email };
    const sent = resolve ? { status: "resolved" } : { assignedTo: me.id };
    const change = deferChange({
      commit: async () => {
        await callOwnerFunction("ticket_update", { ticketId: t.id, ...sent });
        store.succeed(t.id);
      },
      revert: () => store.drop(t.id),
      beacon: () => sendKeepalive("function", "owner-provision-business", { action: "ticket_update", ticketId: t.id, ...sent }),
      beaconReady: keepaliveReady,
      onError: (err) => ui.toast(`Couldn't save that change, so it's back as it was. ${friendlyError(err)}`),
    });
    store.add(t.id, change, shown);
    // one toast whose Undo calls off every change still waiting, so an earlier one never loses its Undo
    ui.toast(pendingToastText(resolve ? "Ticket resolved" : "Ticket assigned to you", store.waiting()), { undo: () => undoAll(store.changes()) });
  }
  useEffect(() => {
    if (ui.phone && selectedId) document.querySelector(".st-detail")?.scrollIntoView({ block: "start" });
  }, [ui.phone, selectedId]);

  async function create(event) {
    event.preventDefault();
    setBusy(true);
    setError("");
    try {
      const result = await callOwnerFunction("ticket_create", draft);
      setCreating(false);
      setDraft(EMPTY_TICKET);
      // a new ticket isn't overdue: decided by the tab shown now (it may have changed while saving). From Waiting too
      // long, show the regular list, which reads it; otherwise read the regular list again. Then open it there.
      setOpenWhenListed(result.ticketId);
      if (overdueRef.current) setStatusFilter("active");
      else { createRefresh.current = true; await loadRef.current(); createRefresh.current = false; }
    } catch (err) {
      setError(friendlyError(err));
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="owner-page st-page">
      <div className="owner-page-heading">
        <div>
          <div className="owner-eyebrow">Operations</div>
          <h1>Support tickets</h1>
          <p>Issues raised for client businesses, who's handling them and where they stand.</p>
        </div>
        <div className="op-heading-actions">
          <button type="button" className="owner-secondary-button" onClick={load} disabled={loading}>
            {loading ? "Loading…" : <><Icon name="refresh" size="sm" />Refresh</>}
          </button>
          <button type="button" className="owner-primary-button" onClick={() => { setCreating(true); selectTicket(null); }}>
            <Icon name="add" size="sm" />New ticket
          </button>
        </div>
      </div>

      {error && <div className="owner-form-error op-gap" role="alert">{error}</div>}

      <div className="ag-filters op-gap" role="tablist">
        {[["active", "Open & in progress"], ["overdue", "Waiting too long"], ...STATUSES, ["all", "All"]].map(([key, text]) => (
          <button key={key} type="button" role="tab" aria-selected={statusFilter === key} className={statusFilter === key ? "active" : ""} onClick={() => setStatusFilter(key)}>
            {text}
          </button>
        ))}
      </div>

      <div className={`st-layout ${detailOpen ? "with-detail" : ""}`}>
        {ui.phone ? (
          <section aria-label="Tickets">
            {tickets.length > 0 && <p className="pn-hint"><Icon name="swipe_left" />Swipe a ticket left to assign it to you or resolve it</p>}
            {!tickets.length ? (loading && !data ? <Skeleton label="Loading tickets" /> : (
              <div className="op-empty">{overdueUnknown ? "Overdue tracking is unavailable until reply times are recorded (a database update is needed)." : emptyIsCurrent ? "No tickets here." : loading ? "Loading tickets..." : "Couldn't load this list. Pull down to try again, or reload the page."}</div>
            )) : (
              <ul className="pn-list pn-swipes">
                {tickets.map((t) => {
                  const done = ["resolved", "closed"].includes(t.status);
                  const waiting = store.has(t.id);   // a quick change still waiting: no other one until it is saved
                  const actions = waiting ? [] : [
                    me && t.assigned_to !== me.id && !done && { key: "assign", label: "Assign", icon: "person_add", tone: "call", onClick: () => quickChange(t, "assign") },
                    !done && { key: "resolve", label: "Resolve", icon: "check", tone: "done", onClick: () => quickChange(t, "resolve") },
                  ].filter(Boolean);
                  return (
                    <SwipeRow key={t.id} actions={actions}>
                      <div className="pn-row">
                        <button type="button" className="pn-item" aria-pressed={t.id === selectedId} onClick={() => { if (t.id !== selectedId) selectTicket(t.id); setCreating(false); }}>
                          <span className="pn-main"><strong>{t.subject}</strong><small>{t.business_name} · {t.assignee ?? "Unassigned"} · {timeAgo(t.created_at)}</small></span>
                          <span className={`pn-meta ${!waiting && timesKnown && t.overdue === true ? "late" : ""}`}>{waiting ? "Saving" : timesKnown && t.overdue === true ? "No reply yet" : label(STATUSES, t.status)}</span>
                        </button>
                        <button type="button" className="pn-more" aria-label={`More for ${t.subject}`} aria-haspopup="dialog" onClick={() => setRowMenu(t)}><Icon name="more_horiz" /></button>
                      </div>
                    </SwipeRow>
                  );
                })}
              </ul>
            )}
          </section>
        ) : (
        <section className="owner-panel">
          <div className="owner-table-wrap" tabIndex={0}>
            <table className="owner-table">
              <thead><tr><th>Ticket</th>{!detailOpen && <th>Business</th>}<th>Priority</th><th>Status</th>{!detailOpen && <th>Assigned</th>}</tr></thead>
              <tbody>
                {tickets.map((t) => {
                  const open = () => { if (t.id !== selectedId) selectTicket(t.id); setCreating(false); };
                  return (
                    <tr key={t.id} className={`st-row ${t.id === selectedId ? "selected" : ""}`} onClick={open}>
                      <td>
                        <div className="st-ticket-cell">
                          <button type="button" className="st-title owner-table-primary" title={t.subject} aria-pressed={t.id === selectedId} onClick={(e) => { e.stopPropagation(); open(); }}>{t.subject}</button>
                          <span className="owner-table-secondary st-sub">
                            <span className="st-sub-business">{t.business_name} · </span>
                            {t.category ? `${categoryText(t.category)} · ` : ""}{timeAgo(t.created_at)}
                          </span>
                        </div>
                      </td>
                      {!detailOpen && <td className="st-nowrap st-col-business">{t.business_name}</td>}
                      <td><Pill tone={PRIORITY_TONE[t.priority]}>{label(PRIORITIES, t.priority)}</Pill></td>
                      <td>
                        <span className="st-status">
                          <Pill tone={STATUS_TONE[t.status]}>{label(STATUSES, t.status)}</Pill>
                          {timesKnown && t.overdue === true && <Pill tone="danger">No reply yet</Pill>}
                        </span>
                      </td>
                      {!detailOpen && (
                        <td className="st-col-assigned">
                          {t.assignee
                            ? <span className="owner-cell-truncate" title={t.assignee}>{t.assignee}</span>
                            : <span className="op-muted st-nowrap">Unassigned</span>}
                        </td>
                      )}
                    </tr>
                  );
                })}
                {!tickets.length && (
                  <tr><td colSpan={detailOpen ? 3 : 5}><div className="op-empty">{overdueUnknown ? "Overdue tracking starts once reply times are recorded." : emptyIsCurrent ? (
                    statusFilter === "active" ? <>No open tickets. <button type="button" className="owner-secondary-button op-small" onClick={() => { setCreating(true); selectTicket(null); }}>New ticket</button></> : "No tickets here."
                  ) : loading ? "Loading tickets…" : <>Tickets didn't load. <button type="button" className="owner-secondary-button op-small" onClick={load} disabled={loading}>Try again</button></>}</div></td></tr>
                )}
              </tbody>
            </table>
          </div>
        </section>
        )}

        {creating && (
          <form className="wiz-section st-detail" onSubmit={create}>
            <div className="wiz-section-head"><div><h3>New ticket</h3></div></div>
            <div className="st-fields">
              <label className="owner-field">
                <span>Business *</span>
                <select required value={draft.businessId} onChange={(e) => setDraft({ ...draft, businessId: e.target.value })}>
                  <option value="">Select business</option>
                  {(data?.businesses ?? []).map((b) => <option key={b.id} value={b.id}>{b.name}</option>)}
                </select>
              </label>
              <label className="owner-field">
                <span>Subject *</span>
                <input required value={draft.subject} onChange={(e) => setDraft({ ...draft, subject: e.target.value })} />
              </label>
              <label className="owner-field">
                <span>Category</span>
                <input value={draft.category} placeholder="e.g. Phone, AI answers, Billing" onChange={(e) => setDraft({ ...draft, category: e.target.value })} />
              </label>
              <label className="owner-field">
                <span>Priority</span>
                <select value={draft.priority} onChange={(e) => setDraft({ ...draft, priority: e.target.value })}>
                  {PRIORITIES.map(([k, v]) => <option key={k} value={k}>{v}</option>)}
                </select>
              </label>
              <label className="owner-field">
                <span>Description</span>
                <textarea value={draft.description} onChange={(e) => setDraft({ ...draft, description: e.target.value })} />
              </label>
            </div>
            <div className="ic-actions">
              <button type="button" className="owner-secondary-button" onClick={() => setCreating(false)} disabled={busy}>Cancel</button>
              <button type="submit" className="owner-primary-button" disabled={busy}>{busy ? "Creating…" : "Create ticket"}</button>
            </div>
          </form>
        )}

        {selected && !creating && (
          <aside className="wiz-section st-detail">
            <div className="wiz-section-head">
              <div>
                <h3>{selected.subject}</h3>
                <p>
                  <button type="button" className="op-link" onClick={() => onOpenBusiness(selected.business_id)}>{selected.business_name}</button>
                  {" · "}opened {formatDateTime(selected.created_at)}
                  {selected.creator && <> by <span className="owner-cell-truncate st-creator" title={selected.creator}>{selected.creator}</span></>}
                </p>
              </div>
              <button type="button" className="owner-modal-close" aria-label="Close ticket" onClick={() => selectTicket(null)}><Icon name="close" size="sm" /></button>
            </div>

            {selected.description && <p className="st-description">{selected.description}</p>}
            <p className="op-muted st-response">
              {!timesKnown
                ? "Reply times aren't available yet (they need the latest database update)."
                : selected.firstResponseHours !== null && selected.firstResponseHours !== undefined
                ? firstReplyText(selected.firstResponseHours)
                : `No reply yet: open for ${businessHoursText(selected.ageHours) || "under a business hour"}${selected.overdue === true ? `, past the ${data?.supportHours?.first_response_hours ?? 4} business hour goal` : ""}.`}
            </p>

            <div className="st-fields">
              <label className="owner-field">
                <span>Status</span>
                <select value={selected.status} disabled={busy} onChange={(e) => update({ status: e.target.value })}>
                  {STATUSES.map(([k, v]) => <option key={k} value={k}>{v}</option>)}
                </select>
              </label>
              <label className="owner-field">
                <span>Priority</span>
                <select value={selected.priority} disabled={busy} onChange={(e) => update({ priority: e.target.value })}>
                  {PRIORITIES.map(([k, v]) => <option key={k} value={k}>{v}</option>)}
                </select>
              </label>
              <label className="owner-field">
                <span>Assigned to</span>
                <select value={selected.assigned_to ?? ""} disabled={busy} onChange={(e) => update({ assignedTo: e.target.value })}>
                  <option value="">Unassigned</option>
                  {(data?.assignees ?? []).map((a) => <option key={a.id} value={a.id}>{a.email}</option>)}
                </select>
              </label>
            </div>

            <div className="st-notes">
              <h4>Conversation with the business</h4>
              {data?.conversations !== true ? (
                <p className="op-muted">Conversations with businesses aren't available yet: they need the latest database update (sql/zella_support_replies.sql).</p>
              ) : selected.messages?.length ? (
                <ul>
                  {selected.messages.map((m, i) => (
                    <li key={i}>
                      <p>{m.text}</p>
                      <span>{m.side === "zella" ? `Zella Voice (${m.author ?? "support"})` : selected.business_name} · {formatDateTime(m.created_at)}</span>
                    </li>
                  ))}
                </ul>
              ) : <p className="op-muted">No replies yet. The business sees everything in this conversation.</p>}
              {data?.conversations === true && (
                <>
                  <textarea className="wiz-textarea" aria-label="Reply to the business" value={reply} maxLength={4000} placeholder="Write a reply the business will see" onChange={(e) => setReply(e.target.value)} />
                  <button type="button" className="owner-primary-button op-gap-top" disabled={busy || !reply.trim() || reply.length > 4000} onClick={() => update({ reply })}>
                    {busy ? "Sending…" : "Send reply"}
                  </button>
                </>
              )}
            </div>

            <div className="st-notes">
              <h4>Internal notes</h4>
              {selected.notes.length ? (
                <ul>
                  {selected.notes.map((n, i) => (
                    <li key={i}>
                      <p>{n.text}</p>
                      <span>{n.author ?? "Unknown"} · {formatDateTime(n.created_at)}</span>
                    </li>
                  ))}
                </ul>
              ) : <p className="op-muted">No notes yet. Only Zella Voice admins can see these.</p>}
              <textarea className="wiz-textarea" value={note} placeholder="Add a note for the Zella Voice team" onChange={(e) => setNote(e.target.value)} />
              <button type="button" className="owner-secondary-button op-gap-top" disabled={busy || !note.trim()} onClick={() => update({ note })}>
                {busy ? "Saving…" : "Add note"}
              </button>
            </div>
          </aside>
        )}
      </div>
      {rowMenu && (
        <BottomSheet title={rowMenu.subject} description={`${rowMenu.business_name} · ${label(STATUSES, rowMenu.status)}`} size="fit" onClose={() => setRowMenu(null)}>
          <div className="pn-menu-list">
            <button type="button" className="pn-row-link" onClick={() => { const t = rowMenu; setRowMenu(null); selectTicket(t.id); setCreating(false); }}><Icon name="open_in_new" /><span>Open ticket</span></button>
            {store.has(rowMenu.id) && <p className="pn-hint" role="status"><Icon name="schedule" />A change to this ticket is about to be saved. Undo it from the message, or wait a moment.</p>}
            {!store.has(rowMenu.id) && me && rowMenu.assigned_to !== me.id && !["resolved", "closed"].includes(rowMenu.status) && (
              <button type="button" className="pn-row-link" onClick={() => { const t = rowMenu; setRowMenu(null); quickChange(t, "assign"); }}><Icon name="person_add" /><span>Assign to me</span></button>
            )}
            {!store.has(rowMenu.id) && !["resolved", "closed"].includes(rowMenu.status) && (
              <button type="button" className="pn-row-link" onClick={() => { const t = rowMenu; setRowMenu(null); quickChange(t, "resolve"); }}><Icon name="check" /><span>Resolve</span></button>
            )}
            <button type="button" className="pn-row-link" onClick={() => { const t = rowMenu; setRowMenu(null); onOpenBusiness(t.business_id); }}><Icon name="storefront" /><span>Open {rowMenu.business_name}</span></button>
          </div>
        </BottomSheet>
      )}
    </section>
  );
}
