import { useCallback, useEffect, useRef, useState } from "react";
import { useDialogFocus } from "../useDialogFocus";
import { addLeaveGuard } from "../router";
import { Icon } from "../BusinessUI";
import { humanize } from "../copy/labels";

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
        <div key={label}><dt>{label}</dt><dd>{value === null || value === undefined || value === "" ? "None" : value}</dd></div>
      ))}
    </dl>
  );
}

// fit: the field is as wide as its control's content (a short select such as a period), not the whole row.
export function Field({ label, hint, error, children, full, fit }) {
  return (
    <label className={`zs-field ${full ? "full" : ""} ${fit ? "fit" : ""} ${error ? "has-error" : ""}`}>
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
      {children && <div>{children}</div>}
      {have && <div className="zs-needs-have"><span>What works today:</span> {have}</div>}
    </div>
  );
}

// Runs a loader; keeps data, loading and error together.
export function useAsync(loader, deps) {
  const [state, setState] = useState({ data: null, error: "", loading: true });
  const live = useRef(true);
  const request = useRef(0);
  const run = useCallback(async () => {
    const id = ++request.current;
    setState((s) => ({ ...s, loading: true, error: "" }));
    try {
      const data = await loader();
      if (live.current && id === request.current) setState({ data, error: "", loading: false });
    } catch (err) {
      if (live.current && id === request.current) setState((s) => ({ ...s, error: err?.message || String(err), loading: false }));
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps);
  useEffect(() => {
    live.current = true;
    setState({ data: null, error: "", loading: true });
    run();
    return () => { live.current = false; ++request.current; };
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
      setValues((current) => {
        const merged = { ...current };
        for (const key of Object.keys(kept)) {
          if (JSON.stringify(current[key]) === JSON.stringify(values[key])) merged[key] = kept[key];
        }
        return merged;
      });
      setStatus({ text: message, error: "" });
    } catch (err) {
      // A save made of several requests can fail partway: what the server already stored counts as saved.
      if (err?.acknowledged && typeof err.acknowledged === "object") setSaved((s) => ({ ...s, ...err.acknowledged }));
      setStatus({ text: "", error: err?.message || String(err) });
    } finally {
      setBusy(false);
    }
  }
  const cancel = () => { setValues(saved); setStatus({ text: "", error: "" }); };
  return { values, setValues, set, dirty, busy, status, save, cancel, saved };
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

// One setting as a compact row: the label and help on the left, the control on the right. The setting key goes in a
// "Technical details" disclosure instead of under every label. `unavailable` shows a neutral badge in place of the
// control (the database update that adds the setting hasn't been applied).
export function SettingRow({ label, help, technical, unavailable, children }) {
  return (
    <div className="zs-row">
      <div className="zs-row-text">
        <span className="zs-row-label">{label}</span>
        {help && <small className="zs-row-help">{help}</small>}
        {technical && (
          <details className="zs-tech">
            <summary>Technical details</summary>
            <div>{technical}</div>
          </details>
        )}
      </div>
      <div className="zs-row-control">
        {unavailable ? <Pill>Not available yet</Pill> : children}
      </div>
    </div>
  );
}

// How many values in a form differ from what was saved.
export function changedCount(form) {
  const saved = form.saved ?? {};
  return Object.keys(form.values).filter((k) => JSON.stringify(form.values[k]) !== JSON.stringify(saved[k])).length;
}

// One save bar per section, sticky at the bottom of the card. It appears only once something changed (or to say the
// save worked or failed): "2 unsaved changes", Discard, Save.
export function SectionSaveBar({ form, onSave, disabled, label = "Save" }) {
  const count = changedCount(form);
  const message = form.status.error || (!form.dirty && form.status.text);
  if (!form.dirty && !message) return null;
  return (
    <div className="zs-sectionbar" role="region" aria-label="Unsaved changes">
      <span className="zs-sectionbar-state">
        {form.status.error ? <span className="zs-error-text" role="alert">{form.status.error}</span>
          : form.dirty ? `${count || 1} unsaved ${count === 1 ? "change" : "changes"}`
            : <span role="status">{form.status.text}</span>}
      </span>
      {form.dirty && (
        <>
          <button type="button" className="zs-btn sm" onClick={form.cancel} disabled={form.busy}>Discard</button>
          <button type="button" className="zs-btn sm primary" onClick={onSave} disabled={form.busy || disabled}>{form.busy ? "Saving…" : label}</button>
        </>
      )}
    </div>
  );
}

// Settings that exist in the app but not yet in the database, said once at the top instead of one warning per row.
export function MissingSettings({ items }) {
  if (!items?.length) return null;
  const count = ["No", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten"][items.length] ?? String(items.length);
  return (
    <div className="banner-info zs-missing" role="status">
      <Icon name="info" />
      <div>
        <strong>{count} {items.length === 1 ? "setting is" : "settings are"} waiting for a database update.</strong>
        <details>
          <summary>Show which</summary>
          <ul>{items.map((i) => <li key={i}>{i}</li>)}</ul>
        </details>
      </div>
    </div>
  );
}

// Confirmation for consequential actions. With `word`, the person types it;
// with `reason`, a reason is required and passed to onConfirm.
export function Confirm({ title, children, confirmLabel = "Confirm", danger, word, reason, onConfirm, onClose, keepOpenOnFalse = false }) {
  const [typed, setTyped] = useState("");
  const [why, setWhy] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const ready = (!word || typed.trim() === word) && (!reason || why.trim().length >= 3);
  const dialogRef = useDialogFocus(onClose, busy);
  async function go() {
    setBusy(true);
    setError("");
    try {
      if (await onConfirm(why.trim()) === false && keepOpenOnFalse) {
        setBusy(false);
        return;
      }
      onClose();
    } catch (err) {
      setError(err?.message || String(err));
      setBusy(false);
    }
  }
  return (
    <div className="zs-overlay" role="presentation" onMouseDown={(e) => { if (e.target === e.currentTarget && !busy) onClose(); }}>
      <div ref={dialogRef} tabIndex={-1} className={`zs-dialog ${danger ? "danger" : ""}`} role="dialog" aria-modal="true" aria-labelledby="zs-dialog-title">
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
    <div className="zs-table-wrap" tabIndex={0}>
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

export const words = humanize;
export const when = (v) => (v ? new Date(v).toLocaleString("en-US", { month: "short", day: "numeric", year: "numeric", hour: "numeric", minute: "2-digit" }) : "None");
export const money = (n, currency = "USD") => (n === null || n === undefined ? "None" : Number(n).toLocaleString("en-US", { style: "currency", currency: currency || "USD" }));
