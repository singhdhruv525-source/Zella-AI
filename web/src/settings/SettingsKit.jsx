import { useCallback, useEffect, useRef, useState } from "react";
import { addLeaveGuard } from "../router";
import { Icon } from "../BusinessUI";

// Building blocks for settings pages in both apps. Styling comes from
// settings.css, which maps to each app's own colour tokens.

export function Card({ title, sub, actions, children, flush }) {
  return (
    <section className="zs-card">
      {(title || actions) && (
        <div className="zs-card-head">
          <div>{title && <h3>{title}</h3>}{sub && <p>{sub}</p>}</div>
          {actions && <div className="zs-actions">{actions}</div>}
        </div>
      )}
      <div className={flush ? "zs-card-flush" : "zs-card-body"}>{children}</div>
    </section>
  );
}

export function Pill({ tone = "", children }) {
  return <span className={`zs-pill ${tone}`}>{children}</span>;
}

export function Facts({ rows }) {
  return (
    <dl className="zs-facts">
      {rows.filter(Boolean).map(([label, value]) => (
        <div key={label}><dt>{label}</dt><dd>{value === null || value === undefined || value === "" ? "—" : value}</dd></div>
      ))}
    </dl>
  );
}

export function Field({ label, hint, error, children, full }) {
  return (
    <label className={`zs-field ${full ? "full" : ""} ${error ? "has-error" : ""}`}>
      <span>{label}</span>
      {children}
      {error ? <small className="zs-error-text" role="alert">{error}</small> : hint && <small>{hint}</small>}
    </label>
  );
}

export function Toggle({ on, onChange, label, disabled }) {
  return (
    <button type="button" role="switch" aria-checked={Boolean(on)} aria-label={label} disabled={disabled}
      className={`zs-switch ${on ? "on" : ""}`} onClick={() => onChange(!on)}><span /></button>
  );
}

export function Banner({ tone = "", children }) {
  if (!children) return null;
  return <div className={`zs-banner ${tone}`} role={tone === "error" ? "alert" : "status"}>{children}</div>;
}

export function Empty({ title, children }) {
  return <div className="zs-empty-box">{title && <strong>{title}</strong>}{children && <span>{children}</span>}</div>;
}

export function Loading() {
  return <p className="zs-muted" aria-busy="true">Loading…</p>;
}

// Shown where a setting needs something that doesn't exist yet. Says exactly
// what is missing, so nothing pretends to work.
export function Needs({ title = "Not available yet", children, have }) {
  return (
    <div className="zs-needs">
      <strong>{title}</strong>
      <div>{children}</div>
      {have && <div className="zs-needs-have"><span>What works today:</span> {have}</div>}
    </div>
  );
}

// Runs a loader; keeps data, loading and error together.
export function useAsync(loader, deps) {
  const [state, setState] = useState({ data: null, error: "", loading: true });
  const live = useRef(true);
  const run = useCallback(async () => {
    setState((s) => ({ ...s, loading: true, error: "" }));
    try {
      const data = await loader();
      if (live.current) setState({ data, error: "", loading: false });
    } catch (err) {
      if (live.current) setState((s) => ({ ...s, error: err?.message || String(err), loading: false }));
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps);
  useEffect(() => {
    live.current = true;
    run();
    return () => { live.current = false; };
  }, [run]);
  return { ...state, reload: run };
}

export function LoadState({ state, children, empty }) {
  if (state.error) return <Banner tone="error">Couldn't load this: {state.error} <button type="button" className="zs-link" onClick={state.reload}>Try again</button></Banner>;
  if (state.loading && !state.data) return <Loading />;
  if (empty && empty(state.data)) return empty === true ? null : <Empty title="Nothing here yet" />;
  return children(state.data);
}

// A form with Save and Cancel. Unsaved changes are protected: leaving the page,
// Back/Forward or closing the tab asks first.
export function useForm(initial) {
  const [saved, setSaved] = useState(initial);
  const [values, setValues] = useState(initial);
  const [status, setStatus] = useState({ text: "", error: "" });
  const [busy, setBusy] = useState(false);
  const dirty = JSON.stringify(values) !== JSON.stringify(saved);
  const dirtyRef = useRef(dirty);
  dirtyRef.current = dirty;
  useEffect(() => addLeaveGuard(() => dirtyRef.current), []);
  const set = (key) => (v) => setValues((f) => ({ ...f, [key]: v?.target ? (v.target.type === "checkbox" ? v.target.checked : v.target.value) : v }));
  async function save(fn, message = "Saved.") {
    setBusy(true);
    setStatus({ text: "", error: "" });
    try {
      const next = await fn(values);
      const kept = next && typeof next === "object" && !Array.isArray(next) ? { ...values, ...next } : values;
      setSaved(kept);
      setValues(kept);
      setStatus({ text: message, error: "" });
    } catch (err) {
      setStatus({ text: "", error: err?.message || String(err) });
    } finally {
      setBusy(false);
    }
  }
  const cancel = () => { setValues(saved); setStatus({ text: "", error: "" }); };
  return { values, setValues, set, dirty, busy, status, save, cancel };
}

export function SaveBar({ form, onSave, disabled, label = "Save changes" }) {
  return (
    <div className="zs-savebar">
      <span className="zs-savebar-state">
        {form.status.error ? <span className="zs-error-text" role="alert">{form.status.error}</span>
          : form.status.text && !form.dirty ? <span role="status">{form.status.text}</span>
            : form.dirty ? "Unsaved changes" : ""}
      </span>
      <button type="button" className="zs-btn" onClick={form.cancel} disabled={!form.dirty || form.busy}>Cancel</button>
      <button type="button" className="zs-btn primary" onClick={onSave} disabled={!form.dirty || form.busy || disabled}>{form.busy ? "Saving…" : label}</button>
    </div>
  );
}

// Confirmation for consequential actions. With `word`, the person types it;
// with `reason`, a reason is required and passed to onConfirm.
export function Confirm({ title, children, confirmLabel = "Confirm", danger, word, reason, onConfirm, onClose }) {
  const [typed, setTyped] = useState("");
  const [why, setWhy] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const ready = (!word || typed.trim() === word) && (!reason || why.trim().length >= 3);
  async function go() {
    setBusy(true);
    setError("");
    try {
      await onConfirm(why.trim());
      onClose();
    } catch (err) {
      setError(err?.message || String(err));
      setBusy(false);
    }
  }
  return (
    <div className="zs-overlay" role="presentation" onMouseDown={(e) => { if (e.target === e.currentTarget && !busy) onClose(); }}>
      <div className={`zs-dialog ${danger ? "danger" : ""}`} role="dialog" aria-modal="true" aria-labelledby="zs-dialog-title">
        <div className="zs-dialog-head">
          <span className="zs-dialog-icon"><Icon name={danger ? "warning" : "task_alt"} /></span>
          <h3 id="zs-dialog-title">{title}</h3>
        </div>
        <div className="zs-dialog-body">{children}</div>
        {reason && <Field label="Reason" hint="Kept in the audit log."><textarea rows={2} value={why} onChange={(e) => setWhy(e.target.value)} autoFocus /></Field>}
        {word && <Field label={`Type ${word} to confirm`}><input value={typed} onChange={(e) => setTyped(e.target.value)} autoFocus={!reason} /></Field>}
        {error && <Banner tone="error">{error}</Banner>}
        <div className="zs-dialog-foot">
          <button type="button" className="zs-btn" onClick={onClose} disabled={busy}>Cancel</button>
          <button type="button" className={`zs-btn ${danger ? "danger" : "primary"}`} onClick={go} disabled={!ready || busy}>{busy ? "Working…" : confirmLabel}</button>
        </div>
      </div>
    </div>
  );
}

export function Table({ columns, rows, empty = "Nothing here yet.", rowKey = (r) => r.id }) {
  if (!rows?.length) return <Empty>{empty}</Empty>;
  return (
    <div className="zs-table-wrap">
      <table className="zs-table">
        <thead><tr>{columns.map(([label]) => <th key={label}>{label}</th>)}</tr></thead>
        <tbody>{rows.map((r, n) => <tr key={rowKey(r) ?? n}>{columns.map(([label, cell]) => <td key={label}>{cell(r)}</td>)}</tr>)}</tbody>
      </table>
    </div>
  );
}

// A row that leads to the page where this is managed.
export function LinkRows({ rows }) {
  return (
    <ul className="zs-rows">
      {rows.filter(Boolean).map(({ title, detail, label = "Open", onClick, right }) => (
        <li key={title}>
          <div><strong>{title}</strong>{detail && <small>{detail}</small>}</div>
          {right}
          {onClick && <button type="button" className="zs-btn sm" onClick={onClick}>{label}</button>}
        </li>
      ))}
    </ul>
  );
}

export const words = (s) => String(s ?? "").replace(/_/g, " ").replace(/^./, (c) => c.toUpperCase());
export const when = (v) => (v ? new Date(v).toLocaleString("en-US", { month: "short", day: "numeric", year: "numeric", hour: "numeric", minute: "2-digit" }) : "—");
export const money = (n, currency = "USD") => (n === null || n === undefined ? "—" : Number(n).toLocaleString("en-US", { style: "currency", currency: currency || "USD" }));
