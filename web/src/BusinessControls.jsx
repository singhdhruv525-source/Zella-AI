import { useEffect, useMemo, useState } from "react";
import { supabase } from "./supabase";
import { Icon, Pill } from "./BusinessUI";
import { Empty, Notice, PageHead, Segment, explain, loadPeople, orThrow, useLoad } from "./BusinessShared";
import { RUN_LABEL, RUN_TONE, RunsPanel, describe } from "./BusinessAutomationRuns";
import { formatDay, formatTime, timeAgo } from "./businessTime";
import { useRoster } from "./BusinessLeads";
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

function AutomationCard({ row, live, canManage, recommended, runs, audits, people, nameOf, tz, onNotice, onChanged }) {
  const fields = AUTOMATION_OPTIONS[row.trigger_type] ?? [];
  const [draft, setDraft] = useState(row.trigger_config ?? {});
  const [open, setOpen] = useState(false);
  const [history, setHistory] = useState(false);
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
  const stateText = row.status === "active" ? "On" : row.status === "paused" ? (live ? "Paused" : "On, starts when you go live") : "Paused (off)";
  const info = describe(row.trigger_type, row.trigger_config ?? {});
  const lastRun = runs[0];
  const nextRun = runs.filter((r) => ["queued", "waiting"].includes(r.status) && r.next_run_at).map((r) => r.next_run_at).sort()[0];
  const failedRecently = runs.filter((r) => r.status === "failed").length;

  return (
    <li className={`ba-auto ${on ? "" : "off"}`}>
      <div className="ba-auto-top">
        <span className="ba-thread-icon"><Icon name="bolt" size="sm" /></span>
        <div className="ba-auto-text">
          <strong>{row.name}{recommended && <Pill tone="info">Start here</Pill>}</strong>
          <small>{row.description}</small>
        </div>
        <div className="ba-auto-side">
          <Pill tone={row.status === "active" ? "success" : on ? "warning" : ""}>{stateText}</Pill>
          {canManage && <Switch on={on} disabled={busy} label={`${row.name} on or off`} onChange={(next) => call(next, null, `${row.name} is ${next ? "on" : "off"}.`)} />}
        </div>
      </div>
      <dl className="ba-auto-facts">
        <div><dt>When</dt><dd>{info.trigger}</dd></div>
        <div><dt>Only if</dt><dd>{info.conditions}</dd></div>
        <div><dt>Then</dt><dd>{info.actions}</dd></div>
        <div><dt>Next run</dt><dd>{row.status !== "active" ? "Not scheduled" : nextRun ? `${formatDay(nextRun, tz)} · ${formatTime(nextRun, tz)}` : "Runs when something triggers it"}</dd></div>
        <div><dt>Last run</dt><dd>{lastRun ? <><Pill tone={RUN_TONE[lastRun.status]}>{RUN_LABEL[lastRun.status] ?? lastRun.status}</Pill> {timeAgo(lastRun.started_at ?? lastRun.created_at)}</> : "Hasn't run yet"}</dd></div>
      </dl>
      <div className="ba-auto-links">
        <button type="button" className="ba-link ba-auto-toggle" aria-expanded={history} onClick={() => setHistory(!history)}>
          {history ? "Hide history" : `History${failedRecently ? ` (${failedRecently} failed)` : ""}`}
        </button>
        {canManage && (row.status === "active" || row.status === "disabled" || row.status === "paused") && (
          <button type="button" className="ba-link ba-auto-toggle" disabled={busy} onClick={() => call(row.status === "disabled", null, `${row.name} is ${row.status === "disabled" ? "on" : "paused"}.`)}>
            {row.status === "disabled" ? "Resume" : "Pause"}
          </button>
        )}
      </div>
      {history && <RunsPanel runs={runs} audits={audits} nameOf={nameOf} people={people} canManage={canManage} tz={tz} onNotice={onNotice} onChanged={onChanged} />}
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

const DENTAL = /dental|dentist|orthodont|clinic|health|medical|physio|chiropract|veterin/i;
// What a clinic should switch on first: reminders, cancellation recovery, missed calls, overdue follow-ups, no-shows.
const START_HERE = ["appointment_reminder", "waitlist_offer", "missed_call_follow_up", "new_lead_callback", "no_show_follow_up"];
const WEEK = 7 * 86400000;

export function AutomationsPage({ workspace, refreshKey, onNotice }) {
  const canManage = canControl(workspace);
  const tz = workspace.timezone;
  const [tab, setTab] = useState("all");
  const roster = useRoster(workspace);
  const { data, error, loading, reload } = useLoad(async () => {
    const list = orThrow(await supabase.from("automations").select("*").eq("business_id", workspace.id).order("name"));
    const f = await supabase.from("followup_tasks").select("id, status, outcome")
      .eq("business_id", workspace.id).order("created_at", { ascending: false }).limit(200);
    // Run history and the audit trail are optional until the latest update is applied.
    const runsRes = await supabase.from("automation_runs").select("*").eq("business_id", workspace.id).order("created_at", { ascending: false }).limit(300);
    const auditRes = await supabase.from("audit_logs").select("*").eq("business_id", workspace.id).eq("entity_type", "automation").order("created_at", { ascending: false }).limit(200);
    const runs = runsRes.error ? [] : runsRes.data ?? [];
    return { list, follows: f.error ? [] : (f.data ?? []), runs, audits: auditRes.error ? [] : auditRes.data ?? [], people: await loadPeople(runs.slice(0, 60).map((r) => r.customer_id)) };
  }, [workspace.id, refreshKey]);

  const follows = data?.follows ?? [];
  const waiting = follows.filter((f) => f.status === "pending" || f.status === "in_progress").length;
  const rebooked = follows.filter((f) => f.outcome === "rescheduled").length;
  const unanswered = follows.filter((f) => f.outcome === "no_answer" || f.outcome === "voicemail").length;
  const live = workspace.onboarding_status === "active" || workspace.receptionist?.status === "active";
  const clinic = DENTAL.test(workspace.industry ?? "");

  const runsFor = (id) => (data?.runs ?? []).filter((r) => r.automation_id === id);
  const auditsFor = (id) => (data?.audits ?? []).filter((a) => a.entity_id === id);
  const failedFor = (id) => runsFor(id).some((r) => r.status === "failed" && Date.now() - new Date(r.created_at).getTime() < WEEK);
  const groups = useMemo(() => {
    const list = [...(data?.list ?? [])];
    if (clinic) list.sort((a, b) => (START_HERE.includes(b.trigger_type) ? 1 : 0) - (START_HERE.includes(a.trigger_type) ? 1 : 0));
    return {
      all: list,
      active: list.filter((a) => a.status === "active"),
      paused: list.filter((a) => a.status !== "active"),
      failed: list.filter((a) => failedFor(a.id)),
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [data, clinic]);
  const shown = groups[tab];
  const failedRuns = (data?.runs ?? []).filter((r) => r.status === "failed" && Date.now() - new Date(r.created_at).getTime() < WEEK).length;
  const doneRuns = (data?.runs ?? []).filter((r) => r.status === "completed" && Date.now() - new Date(r.created_at).getTime() < WEEK).length;

  return (
    <>
      <PageHead crumb="AI & Intelligence / Automations" title="Automations"
        sub={canManage ? "See what's running, what happened, and fix what failed. Changes apply straight away." : "Follow-ups, reminders and check-ins that run for you."} />
      <Notice error={error} onRetry={reload} />
      {data?.list.length > 0 && (
        <>
          <div className="ba-toolbar ba-lead-tools">
            <Segment label="Automation status" value={tab} onChange={setTab}
              options={[["all", `All (${groups.all.length})`], ["active", `Active (${groups.active.length})`], ["paused", `Paused (${groups.paused.length})`], ["failed", `Failed (${groups.failed.length})`]]} />
          </div>
          <p className="ba-muted ba-auto-summary">
            Last 7 days: {doneRuns} {doneRuns === 1 ? "run" : "runs"} finished, {failedRuns} failed
            {follows.length > 0 ? ` · Follow-up calls: ${waiting} waiting, ${rebooked} rebooked, ${unanswered} unanswered` : ""}
            {clinic ? " · Marked “Start here”: the ones most clinics switch on first." : ""}
          </p>
        </>
      )}
      <section className="ba-panel">
        {loading && !data ? <div className="ba-panel-body"><p className="ba-muted">Loading…</p></div> : !data?.list.length ? (
          <div className="ba-panel-body"><Empty title="No automations yet">Zella sets up reminders, missed-call callbacks and no-show follow-ups for you.</Empty></div>
        ) : !shown.length ? (
          <div className="ba-panel-body"><Empty title={tab === "failed" ? "Nothing has failed" : "Nothing here"}>{tab === "failed" ? "Failed runs from the last 7 days would show up here." : "No automations match this view."}</Empty></div>
        ) : (
          <ul className="ba-autos">
            {shown.map((row) => (
              <AutomationCard key={row.id} row={row} live={live} canManage={canManage} recommended={clinic && START_HERE.includes(row.trigger_type)}
                runs={runsFor(row.id)} audits={auditsFor(row.id)} people={data.people} nameOf={roster.nameOf} tz={tz}
                onNotice={onNotice} onChanged={reload} />
            ))}
          </ul>
        )}
      </section>
      {!canManage && <p className="ba-muted ba-gap">Only owners, admins and managers can change automations.</p>}
    </>
  );
}
