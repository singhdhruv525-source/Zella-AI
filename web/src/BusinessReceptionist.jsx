import { ARRIVAL_WINDOW_OPTIONS } from "./onboardingConfig";
import { useState } from "react";
import { supabase } from "./supabase";
import { Field, Pill } from "./BusinessUI";
import { Empty, Notice, friendly, orThrow, useLoad } from "./BusinessShared";
import { PhoneField } from "./formFields";
import { formatDay, formatTime } from "./businessTime";

// Edit the AI receptionist through the versioned flow the database already has
// (sql/zella_workflows.sql): save a draft, check it, publish it, or bring back an
// earlier version. Publishing marks the version for n8n to sync to Vapi; it is
// live once the sync finishes. Owners, admins and managers only (zella_can_manage).

const MANAGE = ["owner", "admin", "manager"];
const AFTER_HOURS = [
  ["take_message", "Take a message and create a callback"],
  ["book_only", "Only book appointments"],
  ["info_only", "Only answer questions"],
];
// Set when a call fetches the receptionist (sql/zella_assistant_delivery.sql): "live" once a call has used this version,
// "failed" when the settings couldn't be sent (the reason is shown). Rules the server checks apply from the next call either way.
const SYNC = { none: ["Not used yet", ""], pending: ["Waiting for the next call", "warning"], live: ["Live on calls", "success"], failed: ["Calls can't use it", "danger"] };
const STATUS = { draft: "Draft", valid: "Checked", invalid: "Needs fixes", published: "Published", superseded: "Earlier version" };
const SAY = {
  NOT_ALLOWED: "Only an owner, admin or manager can change the receptionist.",
  NOT_VALID: "Fix the problems listed before publishing.",
  ALREADY_PUBLISHED: "This version is already published.",
  OLD_VERSION_NOT_VALID_ANY_MORE: "That earlier version no longer passes the checks, so it can't be brought back.",
};
const say = (error) => {
  const code = Object.keys(SAY).find((k) => (error?.message ?? "").includes(k));
  return code ? SAY[code] : friendly(error);
};

// When the receptionist may pass a call to a person. The server enforces these once saved (sql/zella_escalation_rules.sql);
// emergencies follow the emergency setting below, never these.
const HANDOVER = [
  ["customer_requests_human", "The caller asks for a person"], ["unknown_answer", "It can't answer and the caller wants more help"],
  ["upset_customer", "The caller is upset"], ["sensitive_issue", "A sensitive or private matter"],
  ["complex_request", "A request too complex for it"], ["billing_question", "A billing or payment question"],
];
const DEFAULT_HANDOVER = ["customer_requests_human", "unknown_answer", "upset_customer"];   // what it did before reasons could be chosen
const num = (v, lo, hi) => { const n = Number(v); return Number.isInteger(n) && n >= lo && n <= hi ? n : null; };

function Editor({ agent, base, onSaved }) {
  const rules = base.escalation_rules ?? {};
  const [form, setForm] = useState({
    system_prompt: base.system_prompt ?? "", personality: base.personality ?? "", tone: base.tone ?? "",
    transfer_enabled: rules.transfer_enabled !== false && Boolean(rules.transfer_number), transfer_number: rules.transfer_number ?? "",
    after_hours_mode: rules.after_hours_mode ?? "take_message", emergency_enabled: rules.emergency_enabled !== false,
    triggers: Array.isArray(rules.triggers) ? rules.triggers.filter((t) => t !== "emergency") : DEFAULT_HANDOVER,
    restrictions: (Array.isArray(base.knowledge_base?.restrictions) ? base.knowledge_base.restrictions : []).join("\n"),
    booking_notes: base.appointment_rules?.notes ?? "",
    default_minutes: base.appointment_rules?.default_minutes ?? "", min_notice_hours: base.appointment_rules?.min_notice_hours ?? "",
    max_days_ahead: base.appointment_rules?.max_days_ahead ?? "", buffer_minutes: base.appointment_rules?.buffer_minutes ?? "",
    arrival_window_minutes: String(base.appointment_rules?.arrival_window_minutes ?? 0),
  });
  const [busy, setBusy] = useState(false);
  const [result, setResult] = useState(null); // { versionId, errors }
  const [problem, setProblem] = useState("");
  const set = (k) => (e) => setForm({ ...form, [k]: e?.target ? (e.target.type === "checkbox" ? e.target.checked : e.target.value) : e });

  async function saveAndCheck(event) {
    event.preventDefault();
    if (form.transfer_enabled && (!form.transfer_number || String(form.transfer_number).startsWith("?"))) {
      return setProblem("Enter the number calls are passed to, with its country code.");
    }
    setBusy(true);
    setProblem("");
    setResult(null);
    try {
      const config = {
        ...base,
        system_prompt: form.system_prompt.trim(), personality: form.personality.trim() || null, tone: form.tone.trim() || null,
        escalation_rules: {
          ...rules, transfer_enabled: form.transfer_enabled, transfer_number: form.transfer_enabled ? form.transfer_number : rules.transfer_number ?? null,
          after_hours_mode: form.after_hours_mode, emergency_enabled: form.emergency_enabled,
          triggers: form.triggers,
        },
        knowledge_base: { ...(base.knowledge_base ?? {}), restrictions: form.restrictions.split("\n").map((l) => l.trim()).filter(Boolean).slice(0, 50) },
        appointment_rules: {
          ...(base.appointment_rules ?? {}), notes: form.booking_notes.trim(),
          default_minutes: num(form.default_minutes, 5, 480), min_notice_hours: num(form.min_notice_hours, 0, 720),
          max_days_ahead: num(form.max_days_ahead, 1, 365), buffer_minutes: num(form.buffer_minutes, 0, 120),
          arrival_window_minutes: Number(form.arrival_window_minutes) || 0,
        },
      };
      const versionId = orThrow(await supabase.rpc("zella_save_agent_config_draft", { p_agent_id: agent.id, p_config: config }));
      const errors = orThrow(await supabase.rpc("zella_validate_agent_config", { p_version_id: versionId }));
      setResult({ versionId, errors: Array.isArray(errors) ? errors : [] });
      onSaved(false);
    } catch (err) {
      setProblem(say(err));
    } finally {
      setBusy(false);
    }
  }

  async function publish() {
    if (!window.confirm("Publish these changes? Booking, handover and knowledge rules apply from the next call. Changes to what it says (instructions, greeting, owner's rules) reach the phone line once the assistant is updated, which Zella Voice support does for now.")) return;
    setBusy(true);
    setProblem("");
    const { data, error } = await supabase.rpc("zella_publish_agent_config", { p_version_id: result.versionId });
    setBusy(false);
    if (error) return setProblem(say(error));
    setResult(null);
    onSaved(true, data);
  }

  return (
    <form className="ba-panel" onSubmit={saveAndCheck}>
      <div className="ba-panel-head"><div className="ba-panel-title"><div><h2>What your receptionist says and does</h2><p>Changes are saved as a new version and checked before they can go live.</p></div></div></div>
      <div className="ba-panel-body">
        <div className="ba-form-grid">
          <Field label="Instructions" hint="How to greet callers, what to offer, what never to say. At least 20 characters. Never paste passwords or keys here." full>
            <textarea rows={8} value={form.system_prompt} onChange={set("system_prompt")} maxLength={20000} />
          </Field>
          <Field label="Personality" hint="For example: warm, efficient, never rushed."><input value={form.personality} onChange={set("personality")} maxLength={300} /></Field>
          <Field label="Tone" hint="For example: friendly and professional."><input value={form.tone} onChange={set("tone")} maxLength={300} /></Field>
          <Field label="After hours" full>
            <select value={form.after_hours_mode} onChange={set("after_hours_mode")}>
              {AFTER_HOURS.map(([k, t]) => <option key={k} value={k}>{t}</option>)}
            </select>
          </Field>
          <label className="ba-check full"><input type="checkbox" checked={form.transfer_enabled} onChange={set("transfer_enabled")} /><span>Pass callers to a person when they ask</span></label>
          {form.transfer_enabled && (
            <Field label="Pass calls to" bare full><PhoneField value={form.transfer_number} onChange={set("transfer_number")} label="Transfer number" /></Field>
          )}
          <label className="ba-check full"><input type="checkbox" checked={form.emergency_enabled} onChange={set("emergency_enabled")} /><span>Treat emergencies as urgent (flag the call and alert the owners at once)</span></label>
          {form.transfer_enabled && (
            <fieldset className="ba-fieldset full">
              <legend>Pass a call to a person only when</legend>
              <p className="ba-muted">Zella checks this on every call: other calls get a message or a callback instead. Emergencies follow the setting above.</p>
              {HANDOVER.map(([k, label]) => (
                <label key={k} className="ba-check"><input type="checkbox" checked={form.triggers.includes(k)}
                  onChange={(e) => setForm({ ...form, triggers: e.target.checked ? [...form.triggers, k] : form.triggers.filter((t) => t !== k) })} /><span>{label}</span></label>
              ))}
            </fieldset>
          )}
          <Field label="Things it must never say or do" hint="One per line. The receptionist follows these as instructions; Zella can't check them on its own, so keep anything that must be enforced in the booking rules below." full>
            <textarea rows={4} value={form.restrictions} onChange={set("restrictions")} maxLength={15000} placeholder={"Never give medical advice\nNever promise a same-day appointment"} />
          </Field>
          <fieldset className="ba-fieldset full">
            <legend>Booking rules (Zella enforces these)</legend>
            <p className="ba-muted">Times offered, bookings and moves always keep to these. Leave a box empty for no limit.</p>
            <div className="ba-form-grid">
              <Field label="Usual length (minutes)"><input type="number" min={5} max={480} value={form.default_minutes} onChange={set("default_minutes")} /></Field>
              <Field label="Gap between bookings (minutes)"><input type="number" min={0} max={120} value={form.buffer_minutes} onChange={set("buffer_minutes")} /></Field>
              <Field label="Minimum notice (hours)"><input type="number" min={0} max={720} value={form.min_notice_hours} onChange={set("min_notice_hours")} /></Field>
              <Field label="Book up to (days ahead)"><input type="number" min={1} max={365} value={form.max_days_ahead} onChange={set("max_days_ahead")} /></Field>
              <Field label="Callers are offered" hint="With a window, the whole window is held for one team member and callers hear the team arrives within it.">
                <select value={form.arrival_window_minutes} onChange={set("arrival_window_minutes")}>
                  {ARRIVAL_WINDOW_OPTIONS.map(([v, label]) => <option key={v} value={String(v)}>{label}</option>)}
                </select>
              </Field>
            </div>
          </fieldset>
          <Field label="Booking notes (information for callers)" hint="What the receptionist may tell callers about booking. Notes never change what can be booked: use the rules above for that." full>
            <textarea rows={3} value={form.booking_notes} onChange={set("booking_notes")} maxLength={2000} placeholder="New clients: please arrive 10 minutes early." />
          </Field>
        </div>
        {problem && <div className="ba-banner error" role="alert"><span>{problem}</span></div>}
        {result && (result.errors.length ? (
          <div className="ba-banner error" role="alert"><span><strong>Saved as a draft, but it can't go live yet:</strong> {result.errors.join(" ")}</span></div>
        ) : (
          <div className="ba-banner success" role="status"><span>Checked and ready. Publish to put it live.</span></div>
        ))}
      </div>
      <div className="ba-panel-foot">
        <span />
        <div className="ba-form-actions">
          <button type="submit" className="ba-btn" disabled={busy || form.system_prompt.trim().length < 1}>{busy && !result ? "Checking…" : "Save and check"}</button>
          {result && !result.errors.length && <button type="button" className="ba-btn primary" onClick={publish} disabled={busy}>{busy ? "Publishing…" : "Publish"}</button>}
        </div>
      </div>
    </form>
  );
}

function Versions({ workspace, versions, onRestored }) {
  const [busy, setBusy] = useState("");
  const [problem, setProblem] = useState("");
  async function restore(v) {
    if (!window.confirm(`Bring back version ${v.version}? It's published as a new version.`)) return;
    setBusy(v.id);
    setProblem("");
    const { data, error } = await supabase.rpc("zella_rollback_agent_config", { p_version_id: v.id });
    setBusy("");
    if (error) return setProblem(say(error));
    onRestored(data);
  }
  return (
    <section className="ba-panel">
      <div className="ba-panel-head"><div className="ba-panel-title"><div><h2>Versions</h2><p>Every saved change, newest first.</p></div></div></div>
      <div className="ba-panel-body">
        {problem && <div className="ba-banner error" role="alert"><span>{problem}</span></div>}
        {!versions.length ? <Empty title="No versions yet">The first change you save appears here.</Empty> : (
          <ul className="ba-list">
            {versions.map((v) => {
              const [syncText, syncTone] = SYNC[v.sync_status] ?? [v.sync_status, ""];
              return (
                <li key={v.id} className="ba-list-row">
                  <div>
                    <strong>Version {v.version} · {STATUS[v.status] ?? v.status}</strong>
                    <small>{formatDay(v.created_at, workspace.timezone)} · {formatTime(v.created_at, workspace.timezone)}{v.sync_error ? ` · ${v.sync_error}` : ""}</small>
                  </div>
                  <div className="ba-form-actions">
                    {v.status === "published" && <Pill tone={syncTone}>{syncText}</Pill>}
                    {v.status === "superseded" && <button type="button" className="ba-btn sm" disabled={Boolean(busy)} onClick={() => restore(v)}>{busy === v.id ? "Restoring…" : "Bring back"}</button>}
                  </div>
                </li>
              );
            })}
          </ul>
        )}
      </div>
    </section>
  );
}

export function ReceptionistEditor({ workspace, agent, onNotice }) {
  const canManage = MANAGE.includes(workspace.role);
  const { data, error, loading, reload } = useLoad(async () => {
    if (!agent || !canManage) return null;
    const [current, versions] = await Promise.all([
      supabase.rpc("zella_agent_config_current", { p_agent_id: agent.id }),
      supabase.from("agent_config_versions").select("id, version, status, sync_status, sync_error, created_at, config")
        .eq("agent_id", agent.id).order("version", { ascending: false }).limit(20),
    ]);
    const list = orThrow(versions);
    // Start from what is live; if that can't be read, from the latest published version.
    const base = current.error ? (list.find((v) => v.status === "published")?.config ?? null) : current.data;
    if (!base) throw current.error ?? new Error("The receptionist's settings couldn't be loaded.");
    return { base, versions: list };
  }, [agent?.id, canManage]);

  if (!agent) return null;
  if (!canManage) return <p className="ba-muted pad-top">An owner, admin or manager can change what the receptionist says.</p>;
  return (
    <>
      <Notice error={error} onRetry={reload} />
      {loading && !data && <p className="ba-muted">Loading…</p>}
      {data && (
        <div className="ba-grid-2" style={{ marginTop: 16 }}>
          <Editor key={data.versions.find((v) => v.status === "published")?.id ?? "none"} agent={agent} base={data.base} onSaved={(published, version) => {
            if (published) onNotice?.(`Version ${version} published. Rules apply from the next call; wording changes wait for the assistant update.`);
            reload();
          }} />
          <Versions workspace={workspace} versions={data.versions} onRestored={(version) => { onNotice?.(`Brought back as version ${version}. Rules apply from the next call; wording changes wait for the assistant update.`); reload(); }} />
        </div>
      )}
    </>
  );
}
