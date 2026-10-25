import { useState } from "react";
import { supabase } from "./supabase";
import { Modal } from "./BusinessUI";
import { explain } from "./BusinessShared";
import { useRecordTypes } from "./BusinessRecords";

// Lets an owner or admin write a simple rule of their own. The database checks it again:
// no prices, no promotions, messages under 300 characters.
const KINDS = [
  ["status", "When a record changes status"],
  ["stale", "When a record sits in a status too long"],
  ["visit", "After a completed visit"],
  ["due", "A set time after the last visit"],
];

export function OwnRuleButton({ workspace, onNotice, onSaved }) {
  const [open, setOpen] = useState(false);
  if (!["owner", "admin"].includes(workspace.role)) return null;
  return (
    <>
      <button type="button" className="ba-btn" onClick={() => setOpen(true)}>Write your own rule</button>
      {open && <OwnRule workspace={workspace} onClose={() => setOpen(false)} onSaved={(m) => { setOpen(false); onNotice?.(m); onSaved?.(); }} />}
    </>
  );
}

function OwnRule({ workspace, onClose, onSaved }) {
  const { types } = useRecordTypes(workspace, 0);
  const [kind, setKind] = useState("status");
  const [name, setName] = useState("");
  const [typeKey, setTypeKey] = useState("");
  const [status, setStatus] = useState("");
  const [days, setDays] = useState(3);
  const [message, setMessage] = useState("");
  const [task, setTask] = useState("");
  const [alert, setAlert] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  const type = types.find((t) => t.key === typeKey);
  const statuses = (type?.statuses ?? []).map((s) => (typeof s === "string" ? { key: s, label: s } : s));
  const needsRecord = kind === "status" || kind === "stale";

  function build() {
    const rule = {};
    if (message.trim()) { rule.message = message.trim(); rule.delay_minutes = 1; }
    if (task.trim()) rule.task = { title: `${task.trim()}: {title}`, priority: "normal", due_hours: 24 };
    if (alert.trim()) rule.notify = { title: `${alert.trim()}: {title}`, severity: "warning" };
    if (kind === "status") return ["record_status_action", { type_key: typeKey, rules: [{ status, ...rule }] }];
    if (kind === "stale") return ["record_stale", { type_key: typeKey, status, after_days: Number(days), rule }];
    if (kind === "visit") return ["appointment_followup", { after_days: Number(days), rule: { message: message.trim(), delay_minutes: 1 } }];
    return ["service_due", { days: Number(days), service: task.trim() || "visit" }];
  }

  const hasAction = kind === "visit" ? message.trim() : kind === "due" ? true : message.trim() || task.trim() || alert.trim();
  const ready = name.trim().length >= 3 && hasAction && (!needsRecord || (typeKey && status)) && Number(days) > 0;

  async function save() {
    setBusy(true);
    setError("");
    const [trigger, config] = build();
    const { error: failure } = await supabase.rpc("zella_save_industry_rule", { p_business_id: workspace.id, p_name: name.trim(), p_trigger_type: trigger, p_config: config, p_enabled: true });
    setBusy(false);
    if (failure) {
      const text = String(failure.message ?? "");
      setError(text.includes("NO_MARKETING_OR_PRICES") ? "Messages can't include prices or promotions." : text.includes("MESSAGE_TOO_LONG") ? "Keep the message under 300 characters." : explain(failure));
      return;
    }
    onSaved(`${name.trim()} is saved.`);
  }

  return (
    <Modal title="Write your own rule" description="Pick when it runs, then what happens. Messages can't include prices or promotions." onClose={onClose} busy={busy}
      footer={<><button type="button" className="ba-btn" onClick={onClose} disabled={busy}>Cancel</button><button type="button" className="ba-btn primary" onClick={save} disabled={busy || !ready}>{busy ? "Saving…" : "Save rule"}</button></>}>
      <div className="ba-auto-options">
        <label className="ba-auto-field"><span>Rule name</span><input value={name} maxLength={100} onChange={(e) => setName(e.target.value)} /></label>
        <label className="ba-auto-field"><span>When</span>
          <select value={kind} onChange={(e) => setKind(e.target.value)}>{KINDS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select>
        </label>
        {needsRecord && (
          <>
            <label className="ba-auto-field"><span>Record type</span>
              <select value={typeKey} onChange={(e) => { setTypeKey(e.target.value); setStatus(""); }}>
                <option value="">Choose</option>{types.filter((t) => t.enabled !== false).map((t) => <option key={t.key} value={t.key}>{t.plural}</option>)}
              </select>
            </label>
            <label className="ba-auto-field"><span>Status</span>
              <select value={status} onChange={(e) => setStatus(e.target.value)} disabled={!typeKey}>
                <option value="">Choose</option>{statuses.map((s) => <option key={s.key} value={s.key}>{s.label ?? s.key}</option>)}
              </select>
            </label>
          </>
        )}
        {kind !== "status" && (
          <label className="ba-auto-field"><span>{kind === "stale" ? "Days in that status" : kind === "visit" ? "Days after the visit" : "Days since the last visit"}</span>
            <input type="number" min="1" max="730" value={days} onChange={(e) => setDays(e.target.value)} />
          </label>
        )}
        {kind !== "due" && (
          <label className="ba-auto-field"><span>Message to the customer</span>
            <textarea rows={3} maxLength={300} value={message} onChange={(e) => setMessage(e.target.value)} placeholder="Optional. Plain and helpful, no prices." />
          </label>
        )}
        {(kind === "status" || kind === "stale") && (
          <>
            <label className="ba-auto-field"><span>Add a task for the team</span><input value={task} maxLength={120} onChange={(e) => setTask(e.target.value)} placeholder="Optional, e.g. Call the family" /></label>
            <label className="ba-auto-field"><span>Alert the owners</span><input value={alert} maxLength={120} onChange={(e) => setAlert(e.target.value)} placeholder="Optional, e.g. Needs attention" /></label>
          </>
        )}
        {kind === "due" && <label className="ba-auto-field"><span>What is due</span><input value={task} maxLength={60} onChange={(e) => setTask(e.target.value)} placeholder="e.g. check-up" /></label>}
        {error && <p className="ba-error" role="alert">{error}</p>}
      </div>
    </Modal>
  );
}
