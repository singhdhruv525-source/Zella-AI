import { useCallback, useEffect, useState } from "react";
import "./OwnerPages.css";
import { callOwnerFunction } from "./CreateBusinessWizard";
import { Pill } from "./OwnerOverview";
import { formatDateTime, timeAgo } from "./ownerFormat";

const STATUSES = [["open", "Open"], ["in_progress", "In progress"], ["resolved", "Resolved"], ["closed", "Closed"]];
const PRIORITIES = [["low", "Low"], ["normal", "Normal"], ["high", "High"], ["urgent", "Urgent"]];
const STATUS_TONE = { open: "warning", in_progress: "info", resolved: "success", closed: "neutral" };
const PRIORITY_TONE = { low: "neutral", normal: "neutral", high: "warning", urgent: "danger" };
const label = (pairs, key) => pairs.find(([k]) => k === key)?.[1] ?? key;

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

  const load = useCallback(async () => {
    setLoading(true);
    setError("");
    try {
      setData(await callOwnerFunction("tickets_list"));
    } catch (err) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const tickets = (data?.tickets ?? []).filter((t) =>
    statusFilter === "all" ? true : statusFilter === "active" ? ["open", "in_progress"].includes(t.status) : t.status === statusFilter
  );
  const selected = data?.tickets?.find((t) => t.id === selectedId) ?? null;

  async function update(payload) {
    setBusy(true);
    setError("");
    try {
      await callOwnerFunction("ticket_update", { ticketId: selectedId, ...payload });
      if (payload.note) setNote("");
      await load();
    } catch (err) {
      setError(err.message);
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
      setError(err.message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="owner-page">
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
          <button type="button" className="owner-primary-button" onClick={() => { setCreating(true); setSelectedId(null); }}>
            ＋ New ticket
          </button>
        </div>
      </div>

      {error && <div className="owner-form-error op-gap" role="alert">{error}</div>}

      <div className="ag-filters op-gap" role="tablist">
        {[["active", "Open & in progress"], ...STATUSES, ["all", "All"]].map(([key, text]) => (
          <button key={key} type="button" role="tab" aria-selected={statusFilter === key} className={statusFilter === key ? "active" : ""} onClick={() => setStatusFilter(key)}>
            {text}
          </button>
        ))}
      </div>

      <div className={`st-layout ${selected || creating ? "with-detail" : ""}`}>
        <section className="owner-panel">
          <div className="owner-table-wrap">
            <table className="owner-table">
              <thead><tr><th>Ticket</th><th>Business</th><th>Priority</th><th>Status</th><th>Assigned</th></tr></thead>
              <tbody>
                {tickets.map((t) => (
                  <tr key={t.id} className={`st-row ${t.id === selectedId ? "selected" : ""}`} onClick={() => { setSelectedId(t.id); setCreating(false); }}>
                    <td>
                      <div className="owner-business-cell">
                        <strong>{t.subject}</strong>
                        <span>{t.category ? `${t.category} · ` : ""}{timeAgo(t.created_at)}</span>
                      </div>
                    </td>
                    <td>{t.business_name}</td>
                    <td><Pill tone={PRIORITY_TONE[t.priority]}>{label(PRIORITIES, t.priority)}</Pill></td>
                    <td><Pill tone={STATUS_TONE[t.status]}>{label(STATUSES, t.status)}</Pill></td>
                    <td>{t.assignee ?? <span className="op-muted">Unassigned</span>}</td>
                  </tr>
                ))}
                {!tickets.length && (
                  <tr><td colSpan={5}><div className="op-empty">{loading && !data ? "Loading tickets..." : "No tickets here."}</div></td></tr>
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
                  {" · "}opened {formatDateTime(selected.created_at)}{selected.creator ? ` by ${selected.creator}` : ""}
                </p>
              </div>
              <button type="button" className="owner-modal-close" aria-label="Close ticket" onClick={() => setSelectedId(null)}>×</button>
            </div>

            {selected.description && <p className="st-description">{selected.description}</p>}

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
              ) : <p className="op-muted">No notes yet. Only Zella admins can see these.</p>}
              <textarea className="wiz-textarea" value={note} placeholder="Add a note for the Zella team" onChange={(e) => setNote(e.target.value)} />
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
