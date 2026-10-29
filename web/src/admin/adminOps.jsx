import { useCallback, useEffect, useState } from "react";
import { createPortal } from "react-dom";
import "../OwnerPages.css";
import { supabase } from "../supabase";
import { Icon } from "../BusinessUI";
import { Pill } from "../OwnerOverview";

// Shared pieces for the admin Voice & numbers, Messaging and Automations pages. Everything is read and changed
// through the zella_admin_* database functions (sql/zella_admin_ops.sql), which check the admin's permission,
// page and filter on the server and write the audit log. Nothing here sends a message or places a call.

export { Pill };

const ERRORS = {
  NOT_ALLOWED: "Your admin role doesn't allow this.",
  REASON_REQUIRED: "Give a short reason (it goes in the audit log).",
  NOT_FOUND: "It no longer exists. Reload the page.",
  NO_CHANGE: "Nothing changed.",
  PAUSE_FIRST: "Pause the number first, then release it.",
  RECENT_CALLS: "This number had calls in the last 24 hours. Wait a day before releasing it.",
  NO_RECEPTIONIST: "This business has no AI receptionist yet, so it has no call routing to change.",
  INVALID_TRANSFER_NUMBER: "Enter the transfer number with its country code, like +15551234567.",
  INVALID_FALLBACK_NUMBER: "Enter the fallback number with its country code, like +15551234567.",
  FALLBACK_NEEDS_NUMBER: "Add a fallback number before routing calls to it.",
  BUSINESS_NOT_LIVE: "This business isn't live yet. Its automations start when it goes live.",
  BUSINESS_NOT_AVAILABLE: "This business is suspended or cancelled.",
  BUSINESS_TEMPLATE: "Business templates are changed by that business, not here.",
  BODY_LENGTH: "The message must be 1 to 1,600 characters.",
  SUBJECT_REQUIRED: "Emails need a subject.",
  BODY_TEXT: "Scripts and links starting javascript: aren't allowed.",
  SMS_NEEDS_STOP: "Marketing texts must tell people how to stop (for example \"Reply STOP to opt out\").",
};

export function friendlyError(error) {
  const raw = String(error?.message ?? error ?? "");
  const [code, ...rest] = raw.split(":");
  if (ERRORS[code.trim()]) return ERRORS[code.trim()];
  if (code.trim() === "NOT_RETRYABLE" || code.trim() === "UNKNOWN_VARIABLES") {
    const detail = rest.join(":").trim();
    return code.trim() === "UNKNOWN_VARIABLES" ? `These variables aren't available for this message: ${detail}` : detail;
  }
  if (/could not find the function|PGRST202/i.test(raw)) return "This page needs a database update (sql/zella_admin_ops.sql).";
  if (/failed to fetch|network/i.test(raw)) return "Couldn't reach the server. Check your connection and try again.";
  return raw || "Something went wrong.";
}

export async function rpc(name, args = {}) {
  const { data, error } = await supabase.rpc(name, args);
  if (error) throw new Error(friendlyError(error));
  return data;
}

// Loads `loader()` now and whenever deps change; `reload()` runs it again.
export function useLoad(loader, deps) {
  const [state, setState] = useState({ data: null, error: "", loading: true });
  const [tick, setTick] = useState(0);
  useEffect(() => {
    let live = true;
    setState((s) => ({ ...s, loading: true, error: "" }));
    loader().then((data) => live && setState({ data, error: "", loading: false }))
      .catch((e) => live && setState((s) => ({ data: s.data, error: friendlyError(e), loading: false })));
    return () => { live = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [...deps, tick]);
  return { ...state, reload: useCallback(() => setTick((t) => t + 1), []) };
}

export const when = (v) => (v ? new Date(v).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" }) : "—");
export const words = (s) => String(s ?? "").replace(/_/g, " ").replace(/^./, (c) => c.toUpperCase());
export const num = (n) => (n === null || n === undefined ? "—" : Number(n).toLocaleString());
export const pct = (n) => (n === null || n === undefined ? "—" : `${n}%`);
export function duration(s) {
  if (s === null || s === undefined) return "—";
  const v = Math.round(Number(s));
  return v < 60 ? `${v} s` : `${Math.floor(v / 60)} min ${v % 60} s`;
}

export const PERIODS = [[1, "Last 24 hours"], [7, "Last 7 days"], [30, "Last 30 days"], [90, "Last 90 days"]];
export const since = (days) => new Date(Date.now() - days * 86400000).toISOString();

export function PageHeader({ title, description, actions }) {
  return (
    <div className="owner-page-heading">
      <div>
        <h1>{title}</h1>
        <p>{description}</p>
      </div>
      {actions && <div className="op-heading-actions">{actions}</div>}
    </div>
  );
}

export function Tabs({ tabs, current, onChange }) {
  return (
    <div className="op-tabs" role="tablist">
      {tabs.map(([key, label, count]) => (
        <button key={key} type="button" role="tab" aria-selected={current === key} className={current === key ? "active" : ""} onClick={() => onChange(key)}>
          {label}{count ? <span className="ao-tab-count">{count}</span> : null}
        </button>
      ))}
    </div>
  );
}

export function Metric({ label, value, note, tone }) {
  return (
    <div className={`owner-stat-card${tone ? ` ao-stat-${tone}` : ""}`}>
      <div className="owner-stat-top"><span>{label}</span></div>
      <div className="owner-stat-value">{value}</div>
      {note && <div className="owner-stat-note">{note}</div>}
    </div>
  );
}

export function Panel({ title, description, action, children }) {
  return (
    <section className="owner-panel ao-panel">
      {(title || action) && (
        <div className="owner-panel-heading">
          <div>
            {title && <h2>{title}</h2>}
            {description && <p>{description}</p>}
          </div>
          {action}
        </div>
      )}
      {children}
    </section>
  );
}

export function ErrorNote({ error, onRetry }) {
  if (!error) return null;
  return (
    <div className="owner-form-error ao-error" role="alert">
      <span>{error}</span>
      {onRetry && <button type="button" className="owner-secondary-button" onClick={onRetry}>Try again</button>}
    </div>
  );
}

// Something the platform can't do yet, said plainly instead of showing a control that does nothing.
export function NotAvailable({ title, children }) {
  return (
    <div className="ao-unavailable">
      <Icon name="info" size="sm" />
      <div><strong>{title}</strong><p>{children}</p></div>
    </div>
  );
}

export function Filters({ children }) {
  return <div className="ao-filters">{children}</div>;
}

export function Select({ label, value, onChange, options, any = "All" }) {
  return (
    <label className="ao-filter">
      <span>{label}</span>
      <select value={value ?? ""} onChange={(e) => onChange(e.target.value || null)}>
        {any !== null && <option value="">{any}</option>}
        {options.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
      </select>
    </label>
  );
}

export function Search({ label = "Search", value, onChange, placeholder }) {
  const [text, setText] = useState(value ?? "");
  useEffect(() => { const t = setTimeout(() => { if (text !== (value ?? "")) onChange(text); }, 350); return () => clearTimeout(t); }, [text, value, onChange]);
  return (
    <label className="ao-filter ao-search">
      <span>{label}</span>
      <input type="search" value={text} placeholder={placeholder} onChange={(e) => setText(e.target.value)} />
    </label>
  );
}

export function Toggle({ label, checked, onChange }) {
  return (
    <label className="ao-filter ao-check">
      <input type="checkbox" checked={Boolean(checked)} onChange={(e) => onChange(e.target.checked)} />
      <span>{label}</span>
    </label>
  );
}

export const PAGE = 25;

export function Pager({ total, offset, onChange }) {
  if (!total || total <= PAGE) return total ? <p className="op-muted ao-pager">{total} shown</p> : null;
  const last = Math.min(offset + PAGE, total);
  return (
    <div className="ao-pager">
      <span className="op-muted">{offset + 1}–{last} of {num(total)}</span>
      <button type="button" className="owner-secondary-button" disabled={offset === 0} onClick={() => onChange(Math.max(0, offset - PAGE))}>Previous</button>
      <button type="button" className="owner-secondary-button" disabled={last >= total} onClick={() => onChange(offset + PAGE)}>Next</button>
    </div>
  );
}

// columns: [header, (row) => cell, className?]
export function DataTable({ columns, rows, empty, onRow, loading, rowKey = (r) => r.id }) {
  if (loading && !rows) return <p className="op-muted">Loading…</p>;
  if (!rows?.length) return <div className="op-empty">{empty}</div>;
  return (
    <div className="owner-table-wrap">
      <table className="owner-table ao-table">
        <thead><tr>{columns.map(([h], i) => <th key={i}>{h}</th>)}</tr></thead>
        <tbody>
          {rows.map((r) => (
            <tr key={rowKey(r)} className={onRow ? "ao-clickable" : ""} onClick={onRow ? () => onRow(r) : undefined}
              tabIndex={onRow ? 0 : undefined} onKeyDown={onRow ? (e) => { if (e.key === "Enter") onRow(r); } : undefined}>
              {columns.map(([, cell, cls], i) => <td key={i} className={cls}>{cell(r)}</td>)}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

export function Drawer({ title, icon = "info", onClose, children }) {
  useEffect(() => {
    const onKey = (e) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);
  return createPortal(
    <div className="owner-modal-overlay ao-drawer-overlay" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <aside className="owner-modal sa-drawer ao-drawer" role="dialog" aria-modal="true" aria-label={title}>
        <div className="ao-dialog-head ao-drawer-head">
          <span className="ao-dialog-icon"><Icon name={icon} /></span>
          <h3>{title}</h3>
          <button type="button" className="owner-icon-button" aria-label="Close" onClick={onClose}><Icon name="close" size="sm" /></button>
        </div>
        {children}
      </aside>
    </div>,
    document.body
  );
}

export function Facts({ rows }) {
  return (
    <dl className="ao-facts">
      {rows.filter(Boolean).map(([k, v]) => (
        <div key={k}><dt>{k}</dt><dd>{v === null || v === undefined || v === "" ? <span className="op-muted">—</span> : v}</dd></div>
      ))}
    </dl>
  );
}

// A change that needs a reason. The reason is required by the server and kept in the audit log.
export function ReasonDialog({ title, icon = "edit", children, confirmLabel = "Confirm", danger, onConfirm, onClose, word }) {
  const [reason, setReason] = useState("");
  const [typed, setTyped] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  async function go() {
    if (reason.trim().length < 3) return setError("Give a short reason (it goes in the audit log).");
    if (word && typed.trim() !== word) return setError(`Type ${word} to confirm.`);
    setBusy(true); setError("");
    try { await onConfirm(reason.trim()); onClose(); } catch (e) { setError(friendlyError(e)); setBusy(false); }
  }
  return createPortal(
    <div className="owner-modal-overlay" onMouseDown={(e) => e.target === e.currentTarget && !busy && onClose()}>
      <div className={`bd-confirm owner-modal${danger ? " danger" : ""}`} role="dialog" aria-modal="true" aria-label={title}>
        <div className="ao-dialog-head">
          <span className="ao-dialog-icon"><Icon name={icon} /></span>
          <h3>{title}</h3>
        </div>
        <div className="ao-dialog-body">{children}</div>
        <label className="owner-field ao-reason">
          <span>Reason</span>
          <input value={reason} maxLength={300} onChange={(e) => setReason(e.target.value)} placeholder="Why you're doing this" autoFocus />
        </label>
        {word && (
          <label className="owner-field ao-reason">
            <span>Type <strong>{word}</strong> to confirm</span>
            <input value={typed} onChange={(e) => setTyped(e.target.value)} />
          </label>
        )}
        {error && <div className="owner-form-error" role="alert">{error}</div>}
        <div className="ic-actions">
          <button type="button" className="owner-secondary-button" onClick={onClose} disabled={busy}>Cancel</button>
          <button type="button" className={danger ? "bd-danger-button" : "owner-primary-button"} onClick={go} disabled={busy}>{busy ? "Working…" : confirmLabel}</button>
        </div>
      </div>
    </div>,
    document.body
  );
}

// A short message after an action, at the bottom of the screen.
export function useToast() {
  const [toast, setToast] = useState(null);
  useEffect(() => { if (!toast) return undefined; const t = setTimeout(() => setToast(null), 4500); return () => clearTimeout(t); }, [toast]);
  const node = toast && createPortal(<div className={`ao-toast${toast.tone === "error" ? " error" : ""}`} role="status">{toast.text}</div>, document.body);
  return [node, (text, tone) => setToast({ text, tone })];
}

export function AlertList({ alerts, onOpen, empty = "Nothing needs attention." }) {
  if (!alerts) return <p className="op-muted">Loading…</p>;
  if (!alerts.length) return <div className="op-empty ao-ok"><Icon name="check_circle" size="sm" /> {empty}</div>;
  return (
    <ul className="ao-alerts">
      {alerts.map((a, i) => (
        <li key={a.alert_id ?? `${a.kind ?? a.title}-${i}`} className={`ao-alert ${a.severity === "urgent" ? "urgent" : "warning"}`}>
          <Icon name={a.severity === "urgent" ? "error" : "warning"} size="sm" />
          <div>
            <strong>{a.title}</strong>
            <p>{a.detail}</p>
            {a.at && <small className="op-muted">{when(a.at)}</small>}
          </div>
          {onOpen && a.link && <button type="button" className="owner-secondary-button" onClick={() => onOpen(a)}>Open</button>}
        </li>
      ))}
    </ul>
  );
}

// Business and industry choices for filters (from the server; admins can't read businesses directly).
export function useOptions() {
  return useLoad(() => rpc("zella_admin_business_options"), []);
}

// Only decides which buttons to offer; every function checks the permission again on the server.
export const can = (me, permission) => Boolean(me?.permissions?.includes(permission));

export function ProviderHealth({ rows, checksLive, names }) {
  return (
    <div className="ao-providers">
      {names.map(([key, label, role]) => {
        const h = rows?.find((r) => r.provider === key);
        const state = !checksLive ? ["neutral", "Checks off"] : !h ? ["neutral", "Never checked"] : h.ok ? ["success", "Healthy"] : ["danger", "Failing"];
        return (
          <div key={key} className="ao-provider">
            <div className="ao-provider-head"><strong>{label}</strong><Pill tone={state[0]}>{state[1]}</Pill></div>
            <small className="op-muted">{role}</small>
            <Facts rows={[["Last check", when(h?.checked_at)], ["Last healthy", when(h?.last_ok_at)], h && !h.ok ? ["Last error", h.detail] : null,
              h?.failures ? ["Failures in a row", h.failures] : null]} />
          </div>
        );
      })}
    </div>
  );
}
