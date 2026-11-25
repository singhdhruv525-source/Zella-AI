import { useCallback, useEffect, useState } from "react";
import { useDialogFocus } from "../useDialogFocus";
import { createPortal } from "react-dom";
import "../OwnerPages.css";
import { supabase } from "../supabase";
import { Icon } from "../BusinessUI";
import { Pill } from "../OwnerOverview";
import { humanize } from "../copy/labels";
import { formatCount, formatDateTime, formatDuration, formatRelative, formatTime } from "../lib/format.js";

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
  BUSINESS_NOT_AVAILABLE: "This business is suspended or canceled.",
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
  if (/^[A-Z][A-Z0-9_]{2,}$/.test(raw.trim())) return `That didn't work (code ${raw.trim()}). Try again, or check the audit log.`;
  return raw || "Something went wrong. Try again.";
}

export async function rpc(name, args = {}) {
  const { data, error } = await supabase.rpc(name, args);
  if (error) { const e = new Error(friendlyError(error)); e.code = error.code ?? ""; throw e; }   // the code stays for callers that check it
  return data;
}

// Loads `loader()` now and whenever deps change; `reload()` runs it again.
export function useLoad(loader, deps) {
  const [state, setState] = useState({ data: null, error: "", errorCode: "", loading: true });
  const [tick, setTick] = useState(0);
  useEffect(() => {
    let live = true;
    setState({ data: null, loading: true, error: "", errorCode: "" });
    loader().then((data) => live && setState({ data, error: "", errorCode: "", loading: false }))
      .catch((e) => live && setState({ data: null, error: friendlyError(e), errorCode: e?.code ?? "", loading: false }));
    return () => { live = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [...deps, tick]);
  return { ...state, reload: useCallback(() => setTick((t) => t + 1), []) };
}

// A cell or fact with no value is never blank or "None". Short words per kind of value: "Not set" for
// configuration, "Never" for times, "Not available" for counts and lengths the server didn't send (docs/DESIGN_SYSTEM.md,
// Writing). A caller that knows better passes its own words ("No calls yet", "Not recorded").
export function EmptyValue({ label = "Not set" }) {
  return <span className="empty-value">{label}</span>;
}

// Times, counts and lengths go through lib/format.js. The plain functions return a node (EmptyValue when there is no
// value); the *Text versions return a string for sentences, titles and labels.
export const whenText = (v, empty = "Never") => formatDateTime(v) || empty;
export const when = (v, empty = "Never") => (formatDateTime(v) ? <time className="owner-when" dateTime={new Date(v).toISOString()}>{formatDateTime(v)}</time> : <EmptyValue label={empty} />);
// "5 days ago", with the exact time on hover.
export const ago = (v, empty = "Never") => (formatRelative(v) ? <time dateTime={new Date(v).toISOString()} title={formatDateTime(v)}>{formatRelative(v)}</time> : <EmptyValue label={empty} />);
export const words = humanize;
export const numText = (n) => formatCount(n) || "Not available";
export const num = (n) => (formatCount(n) || <EmptyValue label="Not available" />);
export const pct = (n) => (n === null || n === undefined || n === "" ? "Not available" : `${n}%`);
// One length format everywhere: "45 s", "1 min", "2 min 5 s", "1 h 2 min" (lib/format.js).
export const durationText = (s, empty = "Not available") => formatDuration(s) || empty;
export const duration = (s, empty = "Not available") => (formatDuration(s) || <EmptyValue label={empty} />);

// One tone per status word, the same everywhere: Live, Active and Ready are success; Trial, In progress and Scheduled
// are info; Draft, Not yet and Pending are warning. Anything else is neutral unless the page says otherwise.
const TONES = {
  success: ["live", "active", "ready", "healthy", "on", "succeeded", "completed", "done", "paid"],
  info: ["trial", "trialing", "in progress", "scheduled", "running", "queued"],
  warning: ["draft", "not yet", "pending", "waiting", "paused", "past due"],
  danger: ["failed", "failing", "error", "urgent", "suspended", "rejected", "overdue"],
};
export function statusTone(word) {
  const w = String(word ?? "").trim().toLowerCase().replace(/_/g, " ");
  return Object.keys(TONES).find((tone) => TONES[tone].includes(w)) ?? "neutral";
}

export const PERIODS = [[1, "Last 24 hours"], [7, "Last 7 days"], [30, "Last 30 days"], [90, "Last 90 days"]];
export const since = (days) => new Date(Date.now() - days * 86400000).toISOString();

// The one page header. The eyebrow is the sidebar group (Businesses, Configuration, AI and communications,
// Operations), the title is the sidebar label. "Updated 2:44 PM" and Refresh sit in the actions, left of the single
// primary button, so no card carries its own Refresh.
export function PageHeader({ eyebrow, title, description, actions, updatedAt, onRefresh, refreshing }) {
  const updated = formatTime(updatedAt);
  const hasActions = actions || onRefresh || updated;
  return (
    <div className="owner-page-heading">
      <div className="owner-page-heading-copy">
        {eyebrow && <div className="owner-eyebrow">{eyebrow}</div>}
        <h1>{title}</h1>
        {description && <p>{description}</p>}
      </div>
      {hasActions && (
        <div className="op-heading-actions">
          {updated && <span className="op-updated op-muted" title={formatDateTime(updatedAt)}>Updated {updated}</span>}
          {onRefresh && (
            <button type="button" className="owner-secondary-button sm" onClick={onRefresh} disabled={refreshing}>
              <Icon name="refresh" size="sm" />{refreshing ? "Refreshing…" : "Refresh"}
            </button>
          )}
          {actions}
        </div>
      )}
    </div>
  );
}

export function Tabs({ tabs, current, onChange }) {
  return (
    <div className="op-tabs owner-scroll-fade" role="tablist">
      {tabs.map(([key, label, count]) => (
        <button key={key} type="button" role="tab" aria-selected={current === key} className={current === key ? "active" : ""} onClick={() => onChange(key)}>
          {label}{count ? <span className="ao-tab-count">{count}</span> : null}
        </button>
      ))}
    </div>
  );
}

// A stat card's value class: "Not available" (no trustworthy number) is shown in the small note size, never as a
// 32px figure (owner approved 25 Nov 2026, A10).
export const statValueClass = (value) => ["owner-stat-value", value === "Not available" ? "is-na" : ""].join(" ").trim();

// One quiet status in words with a small coloured dot before it (owner approved 25 Nov 2026): the word carries the
// meaning, the dot backs it up. Tones: success, warning, danger, info, neutral.
export function DotText({ tone = "neutral", children, className = "" }) {
  return <span className={`ao-dot-text ${className}`.trim()}><span className={`ao-dot ${tone}`} aria-hidden="true" />{children}</span>;
}

// One KPI card: label, value, one line of note. A card that filters the list is a real button (onClick), with a
// chevron, a hover border and the focus ring; `pressed` marks the filter it applies as on. A warning or danger tone
// puts a small coloured dot before the label; the figure keeps the text colour.
export function Metric({ label, value, note, tone, onClick, pressed }) {
  const body = (
    <>
      <div className="owner-stat-top"><span>{label}</span>{onClick && <Icon name="chevron_right" size="sm" className="owner-stat-chev" />}</div>
      <div className={statValueClass(value)}>{value}</div>
      {note && <div className="owner-stat-note" title={typeof note === "string" ? note : undefined}>{note}</div>}
    </>
  );
  const cls = `owner-stat-card${tone ? ` ao-stat-${tone}` : ""}`;
  if (onClick) {
    return <button type="button" className={`${cls} owner-stat-card--action`} onClick={onClick} aria-pressed={pressed === undefined ? undefined : Boolean(pressed)}>{body}</button>;
  }
  return <div className={cls}>{body}</div>;
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
// `tip` (optional) is a tooltip for the setting behind it, such as "Setting calls_live"; the words never need it.
export function NotAvailable({ title, children, tip }) {
  return (
    <div className="ao-unavailable" title={tip}>
      <Icon name="info" size="sm" />
      <div><strong>{title}</strong><p>{children}</p></div>
    </div>
  );
}

// One row of filters: search first, then selects, dates and toggle chips, and Clear filters as a text button at the
// end. On phones the row folds behind a "Filters (2)" button. `active` is how many filters are set.
export function Filters({ children, active = 0, onClear }) {
  const [open, setOpen] = useState(false);
  return (
    <div className={`ao-filters-wrap${open ? " open" : ""}`}>
      <button type="button" className="owner-secondary-button sm ao-filters-toggle" aria-expanded={open} onClick={() => setOpen((o) => !o)}>
        <Icon name="tune" size="sm" />Filters{active ? ` (${active})` : ""}
      </button>
      <div className="ao-filters op-filters">
        {children}
        {onClear && active > 0 && <button type="button" className="owner-link-button ao-clear" onClick={onClear}>Clear filters</button>}
      </div>
    </div>
  );
}

export function Select({ label, value, onChange, options, any = "All", disabled = false }) {
  return (
    <label className="ao-filter">
      <span>{label}</span>
      <select value={value ?? ""} disabled={disabled} onChange={(e) => onChange(e.target.value || null)}>
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

// A yes or no filter, as a chip in the filter row.
export function Toggle({ label, checked, onChange }) {
  return (
    <button type="button" className={`ao-chip ao-toggle${checked ? " on" : ""}`} aria-pressed={Boolean(checked)} onClick={() => onChange(!checked)}>
      {checked && <Icon name="check" size="sm" />}{label}
    </button>
  );
}

export const PAGE = 25;

// The one table footer, inside the card: what is shown on the left, Previous and Next on the right.
export function Pager({ total, offset = 0, onChange, pageSize = PAGE }) {
  if (!total) return null;
  if (total <= pageSize && offset === 0) {
    return <div className="owner-table-foot ao-pager"><span className="op-muted">{formatCount(total)} shown</span></div>;
  }
  // A list that shrank under a later page (a row paused or resolved) keeps Previous, so the earlier rows stay reachable.
  const last = Math.min(offset + pageSize, total);
  return (
    <div className="owner-table-foot ao-pager">
      <span className="op-muted">{offset >= total ? `Nothing on this page, ${formatCount(total)} in all` : `Showing ${formatCount(offset + 1)} to ${formatCount(last)} of ${formatCount(total)}`}</span>
      <div className="owner-table-foot-nav">
        <button type="button" className="owner-secondary-button sm" aria-label="Previous page" disabled={offset === 0} onClick={() => onChange(Math.max(0, offset - pageSize))}>
          <Icon name="chevron_left" size="sm" /><span className="owner-pager-word">Previous</span>
        </button>
        <button type="button" className="owner-secondary-button sm" aria-label="Next page" disabled={last >= total} onClick={() => onChange(offset + pageSize)}>
          <span className="owner-pager-word">Next</span><Icon name="chevron_right" size="sm" />
        </button>
      </div>
    </div>
  );
}

// columns: [header, (row) => cell, className?, label?]. `label` names the value on a phone card when the header is
// not plain text. Use className "num" for numbers and "col-actions" for the action cell. With `cards`, the table
// becomes one card per row under 600px. `selected(row)` marks the open row.
export function DataTable({ columns, rows, empty, onRow, loading, error, rowKey = (r) => r.id, cards = false, selected }) {
  if (error) return <div className="op-empty" role="status">Results are unavailable. Try again.</div>;
  if (loading) return <p className="op-muted">Loading…</p>;
  if (!rows?.length) return <div className="op-empty">{empty}</div>;
  const labelOf = ([h, , cls, label]) => (String(cls ?? "").includes("col-actions") ? undefined : label ?? (typeof h === "string" ? h : undefined));
  return (
    <div className={`owner-table-wrap${cards ? " owner-table-wrap--cards" : ""}`} tabIndex={0}>
      <table className={`owner-table ao-table${cards ? " owner-table--cards" : ""}`}>
        <thead><tr>{columns.map(([h, , cls], i) => <th key={i} className={cls}>{h}</th>)}</tr></thead>
        <tbody>
          {rows.map((r) => {
            const isSelected = selected ? Boolean(selected(r)) : false;
            const cls = [onRow ? "ao-clickable" : "", isSelected ? "is-selected" : ""].filter(Boolean).join(" ");
            return (
              <tr key={rowKey(r)} className={cls || undefined} aria-selected={selected ? isSelected : undefined} onClick={onRow ? () => onRow(r) : undefined}
                tabIndex={onRow ? 0 : undefined} onKeyDown={onRow ? (e) => { if (e.key === "Enter") onRow(r); } : undefined}>
                {columns.map((col, i) => <td key={i} className={col[2]} data-label={labelOf(col)}>{col[1](r)}</td>)}
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}

// A side panel: a small eyebrow ("Plan"), the title (the business name), an optional status badge, the content, and
// an optional sticky footer for its actions.
export function Drawer({ title, eyebrow, status, onClose, footer, children }) {
  const dialogRef = useDialogFocus(onClose);
  const label = typeof title === "string" ? title : eyebrow;
  return createPortal(
    <div className="owner-modal-overlay ao-drawer-overlay" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <aside ref={dialogRef} tabIndex={-1} className={`owner-modal sa-drawer ao-drawer${footer ? " has-foot" : ""}`} role="dialog" aria-modal="true" aria-label={label}>
        <div className="ao-drawer-head">
          <div className="ao-drawer-title">
            {eyebrow && <span className="ao-drawer-eyebrow">{eyebrow}</span>}
            <h3>{title}</h3>
          </div>
          {status}
          <button type="button" className="owner-icon-button" aria-label="Close" onClick={onClose}><Icon name="close" size="sm" /></button>
        </div>
        <div className="ao-drawer-body">{children}</div>
        {footer && <div className="ao-drawer-foot">{footer}</div>}
      </aside>
    </div>,
    document.body
  );
}

export function Facts({ rows, empty = "Not set" }) {
  return (
    <dl className="ao-facts">
      {rows.filter(Boolean).map(([k, v]) => (
        <div key={k}><dt>{k}</dt><dd>{v === null || v === undefined || v === "" ? <EmptyValue label={empty} /> : v}</dd></div>
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
  const dialogRef = useDialogFocus(onClose, busy);
  async function go() {
    if (reason.trim().length < 3) return setError("Give a short reason (it goes in the audit log).");
    if (word && typed.trim() !== word) return setError(`Type ${word} to confirm.`);
    setBusy(true); setError("");
    try { await onConfirm(reason.trim()); onClose(); } catch (e) { setError(friendlyError(e)); setBusy(false); }
  }
  return createPortal(
    <div className="owner-modal-overlay" onMouseDown={(e) => e.target === e.currentTarget && !busy && onClose()}>
      <div ref={dialogRef} tabIndex={-1} className={`bd-confirm owner-modal${danger ? " danger" : ""}`} role="dialog" aria-modal="true" aria-label={title}>
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

export function AlertList({ alerts, error, onOpen, empty = "Nothing needs attention." }) {
  if (!alerts && error) return <p className="op-muted">Alerts are unavailable. Try again.</p>;
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
            <Facts rows={[["Last check", when(h?.checked_at, "Never")], ["Last healthy", when(h?.last_ok_at, "Never")], h && !h.ok ? ["Last error", h.detail] : null,
              h?.failures ? ["Failures in a row", h.failures] : null]} />
          </div>
        );
      })}
    </div>
  );
}
