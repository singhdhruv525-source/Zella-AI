import { useEffect, useMemo, useState } from "react";
import { supabase } from "./supabase";
import { Icon, Pill } from "./BusinessUI";
import { Empty, Notice, PageHead, explain, orThrow, useLoad } from "./BusinessShared";
import { AUTOMATION_OPTIONS } from "./automationOptions";

const MANAGERS = ["owner", "admin", "manager"];
export const canControl = (workspace) => MANAGERS.includes(workspace.role);

function Switch({ on, onChange, label, disabled }) {
  return (
    <button type="button" role="switch" aria-checked={on} aria-label={label} disabled={disabled}
      className={`ba-switch ${on ? "on" : ""}`} onClick={() => onChange(!on)}>
      <span />
    </button>
  );
}

const sameConfig = (a, b) => JSON.stringify(a ?? {}) === JSON.stringify(b ?? {});

function AutomationCard({ row, live, canManage, onNotice, onChanged }) {
  const fields = AUTOMATION_OPTIONS[row.trigger_type] ?? [];
  const [draft, setDraft] = useState(row.trigger_config ?? {});
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  useEffect(() => setDraft(row.trigger_config ?? {}), [row.trigger_config]);

  const on = row.status === "active" || row.status === "paused";
  const dirty = !sameConfig(draft, row.trigger_config);

  async function call(enabled, config, message) {
    setBusy(true);
    setError("");
    const { error: failure } = await supabase.rpc("zella_set_automation", {
      p_business_id: row.business_id, p_automation_id: row.id, p_enabled: enabled, p_config: config,
    });
    setBusy(false);
    if (failure) return setError(explain(failure));
    onNotice?.(message);
    onChanged();
  }

  const set = (key, value) => setDraft((d) => ({ ...d, [key]: value }));
  const stateText = row.status === "active" ? "On" : row.status === "paused" ? (live ? "Paused" : "On, starts when you go live") : "Off";

  return (
    <li className={`ba-auto ${on ? "" : "off"}`}>
      <div className="ba-auto-top">
        <span className="ba-thread-icon"><Icon name="bolt" size="sm" /></span>
        <div className="ba-auto-text">
          <strong>{row.name}</strong>
          <small>{row.description}</small>
        </div>
        <div className="ba-auto-side">
          <Pill tone={row.status === "active" ? "success" : on ? "warning" : ""}>{stateText}</Pill>
          {canManage && <Switch on={on} disabled={busy} label={`${row.name} on or off`} onChange={(next) => call(next, null, `${row.name} is ${next ? "on" : "off"}.`)} />}
        </div>
      </div>
      {canManage && fields.length > 0 && (
        <>
          <button type="button" className="ba-link ba-auto-toggle" aria-expanded={open} onClick={() => setOpen(!open)}>
            {open ? "Hide options" : "Change options"}
          </button>
          {open && (
            <div className="ba-auto-options">
              {fields.map((f) => (
                <div key={f.key} className="ba-auto-field">
                  <span>{f.label}</span>
                  {f.kind === "chips" ? (
                    <div className="ba-chips">
                      {f.options.map(([value, label]) => {
                        const picked = (draft[f.key] ?? []).includes(value);
                        return (
                          <button key={value} type="button" aria-pressed={picked} className={`ba-chip ${picked ? "on" : ""}`}
                            onClick={() => set(f.key, picked ? (draft[f.key] ?? []).filter((x) => x !== value) : [...(draft[f.key] ?? []), value])}>
                            {label}
                          </button>
                        );
                      })}
                    </div>
                  ) : f.kind === "check" ? (
                    <label className="ba-check"><input type="checkbox" checked={Boolean(draft[f.key])} onChange={(e) => set(f.key, e.target.checked)} /><span>{f.text}</span></label>
                  ) : (
                    <select value={String(draft[f.key] ?? "")} onChange={(e) => set(f.key, typeof f.options[0][0] === "number" ? Number(e.target.value) : e.target.value)}>
                      {draft[f.key] === undefined && <option value="">Choose</option>}
                      {f.options.map(([value, label]) => <option key={value} value={value}>{label}</option>)}
                    </select>
                  )}
                </div>
              ))}
              {error && <p className="ba-error" role="alert">{error}</p>}
              <div className="ba-auto-actions">
                <button type="button" className="ba-btn" disabled={busy || !dirty} onClick={() => setDraft(row.trigger_config ?? {})}>Undo changes</button>
                <button type="button" className="ba-btn primary" disabled={busy || !dirty} onClick={() => call(null, draft, `${row.name} options saved.`)}>{busy ? "Saving…" : "Save options"}</button>
              </div>
            </div>
          )}
        </>
      )}
      {!open && error && <p className="ba-error" role="alert">{error}</p>}
    </li>
  );
}

export function AutomationsPage({ workspace, refreshKey, onNotice }) {
  const canManage = canControl(workspace);
  const { data, error, loading, reload } = useLoad(async () => {
    const list = orThrow(await supabase.from("automations").select("*").eq("business_id", workspace.id).order("name"));
    const f = await supabase.from("followup_tasks").select("id, status, outcome")
      .eq("business_id", workspace.id).order("created_at", { ascending: false }).limit(200);
    return { list, follows: f.error ? [] : (f.data ?? []) };
  }, [workspace.id, refreshKey]);

  const follows = data?.follows ?? [];
  const waiting = follows.filter((f) => f.status === "pending" || f.status === "in_progress").length;
  const rebooked = follows.filter((f) => f.outcome === "rescheduled").length;
  const unanswered = follows.filter((f) => f.outcome === "no_answer" || f.outcome === "voicemail").length;
  const live = workspace.onboarding_status === "active" || workspace.receptionist?.status === "active";
  const onCount = (data?.list ?? []).filter((a) => a.status === "active" || a.status === "paused").length;

  return (
    <>
      <PageHead crumb="AI & Intelligence / Automations" title="Automations"
        sub={canManage ? "Switch each one on or off and change how it works. Changes apply straight away." : "Follow-ups, reminders and check-ins that run for you."} />
      <Notice error={error} onRetry={reload} />
      {data?.list.length > 0 && (
        <p className="ba-muted ba-auto-summary">{onCount} of {data.list.length} on{follows.length > 0 ? ` · Follow-up calls: ${waiting} waiting, ${rebooked} rebooked, ${unanswered} unanswered` : ""}</p>
      )}
      <section className="ba-panel">
        {loading && !data ? <div className="ba-panel-body"><p className="ba-muted">Loading…</p></div> : !data?.list.length ? (
          <div className="ba-panel-body"><Empty title="No automations yet">Zella sets up reminders, missed-call callbacks and no-show follow-ups for you.</Empty></div>
        ) : (
          <ul className="ba-autos">
            {data.list.map((row) => (
              <AutomationCard key={row.id} row={row} live={live} canManage={canManage} onNotice={onNotice} onChanged={reload} />
            ))}
          </ul>
        )}
      </section>
      {!canManage && <p className="ba-muted ba-gap">Only owners, admins and managers can change automations.</p>}
    </>
  );
}
