import { useCallback, useEffect, useRef, useState } from "react";
import "./OwnerPages.css";
import "./SupportTickets.css";
import { callOwnerFunction } from "./CreateBusinessWizard";
import { Pill } from "./OwnerOverview";
import { formatDateTime, timeAgo } from "./ownerFormat";
import { friendlyError } from "./admin/adminOps";
import { businessHoursText } from "./adminAccess";

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

export default function SupportTickets({ onOpenBusiness }) {
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
  const selectTicket = (id) => { setSelectedId(id); setNote(""); setReply(""); };

  // only the latest load may show its result, so an older refresh can't replace the list read after a reply
  const request = useRef(0);
  // Waiting too long asks the server for the overdue tickets themselves (every waiting ticket is judged there), not
  // a filter of the newest tickets loaded for the other tabs
  const overdueTab = statusFilter === "overdue";
  const load = useCallback(async () => {
    const mine = ++request.current;
    setLoading(true);
    setError("");
    try {
      const next = await callOwnerFunction("tickets_list", overdueTab ? { overdue: true } : {});
      if (mine === request.current) setData({ ...next, overdueOnly: overdueTab });
    } catch (err) {
      if (mine === request.current) setError(friendlyError(err));
    } finally {
      if (mine === request.current) setLoading(false);
    }
  }, [overdueTab]);

  useEffect(() => {
    load();
  }, [load]);
  // reply times are known only once the server says conversations are available (sql/zella_support_replies.sql)
  const timesKnown = data?.conversations === true;

  const tickets = (data?.tickets ?? []).filter((t) =>
    statusFilter === "all" ? true : statusFilter === "overdue" ? data?.overdueOnly === true && t.overdue === true : statusFilter === "active" ? ["open", "in_progress"].includes(t.status) : t.status === statusFilter
  );
  const selected = data?.tickets?.find((t) => t.id === selectedId) ?? null;
  // with the detail panel open the table is narrow: Business moves into each row's second line and Assigned is in the panel
  const detailOpen = Boolean(selected || creating);

  async function update(payload) {
    setBusy(true);
    setError("");
    try {
      const r = await callOwnerFunction("ticket_update", { ticketId: selectedId, ...payload });
      // clear only the text that was sent; anything typed since stays
      if (payload.note) setNote((current) => (current === payload.note ? "" : current));
      // the other changes were saved but the reply wasn't: say so, and keep the reply to send again on its own
      if (r?.replyFailed) setError(`The other changes were saved, but the reply wasn't sent: ${r.replyFailed}`);
      else if (payload.reply) setReply((current) => (current === payload.reply ? "" : current));
      await load();
    } catch (err) {
      setError(friendlyError(err));
    } finally {
      setBusy(false);
    }
  }

  async function create(event) {
    event.preventDefault();
    setBusy(true);
    setError("");
    try {
      const result = await callOwnerFunction("ticket_create", draft);
      setCreating(false);
      setDraft(EMPTY_TICKET);
      await load();
      setSelectedId(result.ticketId);
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
          <div className="owner-eyebrow">Support</div>
          <h1>Support tickets</h1>
          <p>Issues raised for client businesses, who's handling them and where they stand.</p>
        </div>
        <div className="op-heading-actions">
          <button type="button" className="owner-secondary-button" onClick={load} disabled={loading}>
            {loading ? "Loading..." : "↻ Refresh"}
          </button>
          <button type="button" className="owner-primary-button" onClick={() => { setCreating(true); selectTicket(null); }}>
            ＋ New ticket
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
                  <tr><td colSpan={detailOpen ? 3 : 5}><div className="op-empty">{loading && !data ? "Loading tickets..." : !data ? "Couldn't load this list. Try again with Refresh, or reload the page." : "No tickets here."}</div></td></tr>
                )}
              </tbody>
            </table>
          </div>
        </section>

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
              <button type="submit" className="owner-primary-button" disabled={busy}>{busy ? "Creating..." : "Create ticket"}</button>
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
              <button type="button" className="owner-modal-close" aria-label="Close ticket" onClick={() => selectTicket(null)}>×</button>
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
                    {busy ? "Sending..." : "Send reply"}
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
                {busy ? "Saving..." : "Add note"}
              </button>
            </div>
          </aside>
        )}
      </div>
    </section>
  );
}
