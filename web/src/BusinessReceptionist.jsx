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
const SYNC = { none: ["Not synced", ""], pending: ["Syncing", "warning"], live: ["Live", "success"], failed: ["Sync failed", "danger"] };
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

function Editor({ agent, base, onSaved }) {
  const rules = base.escalation_rules ?? {};
  const [form, setForm] = useState({
    system_prompt: base.system_prompt ?? "", personality: base.personality ?? "", tone: base.tone ?? "",
    transfer_enabled: rules.transfer_enabled !== false && Boolean(rules.transfer_number), transfer_number: rules.transfer_number ?? "",
    after_hours_mode: rules.after_hours_mode ?? "take_message", emergency_enabled: rules.emergency_enabled !== false,
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
    if (!window.confirm("Publish these changes? Your receptionist uses them on calls once they've synced, usually within a few minutes.")) return;
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
            if (published) onNotice?.(`Version ${version} published. It goes live once it has synced.`);
            reload();
          }} />
          <Versions workspace={workspace} versions={data.versions} onRestored={(version) => { onNotice?.(`Brought back as version ${version}. It goes live once it has synced.`); reload(); }} />
        </div>
      )}
    </>
  );
}
