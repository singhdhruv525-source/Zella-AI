import { useCallback, useState } from "react";
import { navigate } from "../router";
import { N8nConfig, Webhooks } from "../settings/AdminPanels";
import {
  AlertList, DataTable, Drawer, ErrorNote, Facts, Filters, Metric, NotAvailable, PAGE, PageHeader, Pager, Panel, PERIODS, Pill,
  ReasonDialog, Search, Select, Tabs, can, duration, num, pct, rpc, since, useLoad, useOptions, useToast, when, words,
} from "./adminOps";

// Admin page: every business's automations, what they ran, what failed and the scheduler that drives them. Data
// comes from the zella_admin_* functions (sql/zella_admin_ops.sql). Pausing, resuming and retrying change the
// database only; a retry replays the stored event once, and only when nothing from the failed run happened yet.

const TABS = [["overview", "Overview"], ["directory", "Automations"], ["runs", "Runs"], ["failed", "Failed runs"], ["templates", "Templates"], ["infrastructure", "Scheduler & n8n"]];
const tone = (s) => (s === "active" || s === "succeeded" ? "success" : s === "failed" ? "danger" : s === "paused" || s === "running" ? "warning" : "neutral");
const STATUS_LABEL = { disabled: "Archived" };

export default function AutomationsPage({ me, sub, onOpenBusiness }) {
  const tab = TABS.some(([k]) => k === sub) ? sub : "overview";
  const setTab = (k) => navigate(k === "overview" ? "/automations" : `/automations/${k}`);
  const [toast, say] = useToast();
  const options = useOptions();
  return (
    <section className="owner-page ao-page">
      <PageHeader title="Automations" description="Reminders, follow-ups and other automations for every business: their status, every run, failures and the scheduler." />
      <Tabs tabs={TABS} current={tab} onChange={setTab} />
      {tab === "overview" && <Overview onTab={setTab} />}
      {tab === "directory" && <Directory me={me} options={options.data} say={say} onOpenBusiness={onOpenBusiness} />}
      {(tab === "runs" || tab === "failed") && <Runs key={tab} failed={tab === "failed"} me={me} options={options.data} say={say} onOpenBusiness={onOpenBusiness} />}
      {tab === "templates" && <Templates />}
      {tab === "infrastructure" && <Infrastructure />}
      {toast}
    </section>
  );
}

function Overview({ onTab }) {
  const [days, setDays] = useState(30);
  const data = useLoad(() => rpc("zella_admin_automation_overview", { p_from: since(days), p_to: null }), [days]);
  const health = useLoad(() => rpc("zella_admin_scheduler_health"), []);
  const o = data.data;
  const h = health.data;
  const alerts = h ? [
    ...h.alerts,
    ...(h.overdue.reminders ? [{ severity: "warning", title: "Reminders overdue", detail: `${h.overdue.reminders} reminders are more than 15 minutes late.`, link: "infrastructure" }] : []),
    ...(h.overdue.followups ? [{ severity: "warning", title: "Follow-ups overdue", detail: `${h.overdue.followups} follow-ups are more than 15 minutes late.`, link: "infrastructure" }] : []),
    ...(h.overdue.events ? [{ severity: "warning", title: "Events not picked up", detail: `${h.overdue.events} events have waited more than 15 minutes.`, link: "infrastructure" }] : []),
    ...(h.failed_24h.workflows ? [{ severity: "warning", title: "Failed runs in 24 hours", detail: `${h.failed_24h.workflows} workflow runs failed.`, link: "failed" }] : []),
    ...h.dispatch.filter((d) => d.stuck).map((d) => ({ severity: "warning", title: `${words(d.workflow)} looks stuck`, detail: "The same work has been waiting for 12 dispatches in a row.", link: "infrastructure" })),
    ...h.jobs.filter((j) => j.active && j.failures_24h).map((j) => ({ severity: "urgent", title: `Job ${j.name} failing`, detail: `${j.failures_24h} failures in 24 hours. ${j.last_run?.message ?? ""}`, link: "infrastructure" })),
  ] : null;
  const jobsOn = h?.jobs.filter((j) => j.active).length ?? 0;
  return (
    <>
      <Filters>
        <Select label="Period" value={String(days)} any={null} onChange={(v) => setDays(Number(v))} options={PERIODS.map(([d, l]) => [String(d), l])} />
        <button type="button" className="owner-secondary-button" onClick={() => { data.reload(); health.reload(); }}>Refresh</button>
      </Filters>
      <ErrorNote error={data.error} onRetry={data.reload} />
      {h && !h.jobs.some((j) => j.active && j.name === "zella_dispatch") && (
        <NotAvailable title="The scheduler isn't running">The zella_dispatch job is off, so due reminders and follow-ups wait in the queue and nothing is handed to n8n. That's expected before go-live.</NotAvailable>
      )}
      {o && (
        <div className="owner-stat-grid ao-stats">
          <Metric label="Automations" value={num(o.automations.total)} note={`${num(o.automations.active)} active · ${num(o.automations.paused)} paused · ${num(o.automations.disabled)} archived`} />
          <Metric label="Workflow runs succeeded" value={num(o.workflows.succeeded)} note={`Success rate ${pct(o.success_rate)}`} />
          <Metric label="Workflow runs failed" value={num(o.workflows.failed)} tone={o.workflows.failed ? "danger" : null} />
          <Metric label="Running now" value={num(o.workflows.running + o.runs.running)} />
          <Metric label="Average run time" value={duration(o.workflows.avg_seconds)} />
          <Metric label="Need a person" value={num(o.workflows.needs_manual)} tone={o.workflows.needs_manual ? "warning" : null} />
          <Metric label="Waiting in queue" value={num(o.waiting.followups + o.waiting.reminders + o.waiting.events)} note={`${num(o.waiting.reminders)} reminders · ${num(o.waiting.followups)} follow-ups · ${num(o.waiting.events)} events`} />
          <Metric label="Unresolved dead letters" value={num(o.dead_letters_open)} tone={o.dead_letters_open ? "warning" : null} />
        </div>
      )}
      {o?.latest_failure && (
        <NotAvailable title={`Latest failure: ${o.latest_failure.workflow} at ${when(o.latest_failure.at)}`}>{o.latest_failure.error ?? "No error message recorded."}</NotAvailable>
      )}
      <div className="ao-two">
        <Panel title="Needs attention"><ErrorNote error={health.error} onRetry={health.reload} /><AlertList alerts={alerts} onOpen={(a) => onTab(a.link)} /></Panel>
        <Panel title="Scheduler" action={<button type="button" className="owner-secondary-button" onClick={() => onTab("infrastructure")}>Details</button>}>
          {h && <Facts rows={[["Scheduled jobs on", `${jobsOn} of ${h.jobs.length}`], ["Dispatcher switch", h.dispatch_switch ? "On" : "Off"],
            ["n8n address", h.n8n_address_set ? "Set" : "Not set"], ["n8n secret stored", h.n8n_secret_stored ? "Yes" : "No"]]} />}
        </Panel>
      </div>
    </>
  );
}

function Directory({ me, options, say, onOpenBusiness }) {
  const [f, setF] = useState({ q: "", status: null, trigger: null, business: null, industry: null, offset: 0 });
  const set = (k) => (v) => setF((x) => ({ ...x, [k]: v, offset: 0 }));
  const setQ = useCallback((v) => setF((x) => ({ ...x, q: v, offset: 0 })), []);
  const list = useLoad(() => rpc("zella_admin_automations", { p_q: f.q || null, p_status: f.status, p_trigger: f.trigger, p_business: f.business, p_industry: f.industry, p_limit: PAGE, p_offset: f.offset }), [f]);
  const [open, setOpen] = useState(null);
  const [pauseAll, setPauseAll] = useState(false);
  const manage = can(me, "integrations.manage");
  const businessName = options?.businesses.find((b) => b.id === f.business)?.name;
  return (
    <Panel>
      <Filters>
        <Search value={f.q} onChange={setQ} placeholder="Automation, business or trigger" />
        <Select label="Status" value={f.status} onChange={set("status")} options={[["active", "Active"], ["paused", "Paused"], ["disabled", "Archived"]]} />
        <Select label="Trigger" value={f.trigger} onChange={set("trigger")} options={(list.data?.triggers ?? []).map((t) => [t, words(t)])} />
        <Select label="Business" value={f.business} onChange={set("business")} options={(options?.businesses ?? []).map((b) => [b.id, b.name])} />
        <Select label="Industry" value={f.industry} onChange={set("industry")} options={(options?.industries ?? []).map((i) => [i.id, i.name])} />
        {manage && f.business && <button type="button" className="bd-danger-button" onClick={() => setPauseAll(true)}>Pause all for this business</button>}
      </Filters>
      <p className="op-muted">Automations are created from templates when a business is set up, and changed by the business in their app. There is no "create automation" here.</p>
      <ErrorNote error={list.error} onRetry={list.reload} />
      <DataTable loading={list.loading} rows={list.data?.rows} onRow={(r) => setOpen(r.id)} empty="No automations match these filters."
        columns={[
          ["Automation", (r) => <strong>{r.name}</strong>], ["Business", (r) => r.business_name], ["Industry", (r) => r.industry_name ?? "—"],
          ["Trigger", (r) => words(r.trigger_type)], ["Status", (r) => <span className="ao-flags"><Pill tone={tone(r.status)}>{STATUS_LABEL[r.status] ?? r.status}</Pill>
            {!r.business_live && <Pill tone="neutral">Business not live</Pill>}{r.paused_by_suspension && <Pill tone="warning">Suspended</Pill>}</span>],
          ["Runs", (r) => num(r.runs.total)], ["Failed", (r) => (r.runs.failed ? <Pill tone="danger">{r.runs.failed}</Pill> : 0)],
          ["Last run", (r) => when(r.runs.last_at)], ["Updated", (r) => when(r.updated_at)],
        ]} />
      <Pager total={list.data?.total} offset={f.offset} onChange={(o) => setF((x) => ({ ...x, offset: o }))} />
      {open && <AutomationDrawer id={open} onClose={() => setOpen(null)} onOpenBusiness={onOpenBusiness} onChanged={(m) => { say(m); list.reload(); }} />}
      {pauseAll && (
        <ReasonDialog title={`Pause every automation for ${businessName}?`} icon="pause_circle" danger confirmLabel="Pause all" onClose={() => setPauseAll(false)}
          onConfirm={async (reason) => { const r = await rpc("zella_admin_business_automations_pause", { p_business_id: f.business, p_reason: reason }); say(`${r.paused} automation${r.paused === 1 ? "" : "s"} paused.`); list.reload(); }}>
          <p>Every active automation for this business stops sending reminders and follow-ups. Nothing for other businesses changes. Each one can be resumed separately.</p>
        </ReasonDialog>
      )}
    </Panel>
  );
}

function AutomationDrawer({ id, onClose, onOpenBusiness, onChanged }) {
  const d = useLoad(() => rpc("zella_admin_automation_detail", { p_id: id }), [id]);
  const [change, setChange] = useState(null);
  const a = d.data?.automation;
  const queue = (q) => (q ? Object.entries(q).map(([k, v]) => `${words(k)}: ${v}`).join(", ") : "None");
  const settings = a ? Object.entries(a.trigger_config ?? {}).filter(([, v]) => typeof v !== "object") : [];
  const VERB = { active: ["Resume", "Resumed"], paused: ["Pause", "Paused"], disabled: ["Archive", "Archived"] };
  return (
    <Drawer title={a?.name ?? "Automation"} icon="bolt" onClose={onClose}>
      <ErrorNote error={d.error} onRetry={d.reload} />
      {!a ? <p className="op-muted">Loading…</p> : (
        <>
          <Facts rows={[["Business", <button key="b" type="button" className="ao-link" onClick={() => onOpenBusiness(a.business_id)}>{a.business_name}</button>],
            ["Business live", a.business_live ? "Yes" : "No — nothing runs until it goes live"], ["Trigger", words(a.trigger_type)],
            ["Status", <Pill key="s" tone={tone(a.status)}>{STATUS_LABEL[a.status] ?? a.status}</Pill>], a.paused_by_suspension ? ["Paused because", "The business was suspended"] : null,
            ["Description", a.description], ["Created", when(a.created_at)], ["Updated", when(a.updated_at)]]} />
          {settings.length > 0 && <><h3 className="ao-h3">Settings</h3><Facts rows={settings.map(([k, v]) => [words(k), String(v)])} /></>}
          <h3 className="ao-h3">Queue for this business</h3>
          <Facts rows={[["Follow-ups", queue(d.data.queue.followups)], d.data.queue.reminders !== null ? ["Reminders", queue(d.data.queue.reminders)] : null]} />
          <h3 className="ao-h3">Recent runs</h3>
          {d.data.runs.length ? (
            <ol className="ao-timeline">{d.data.runs.map((r) => <li key={r.id}><strong><Pill tone={tone(r.status)}>{r.status}</Pill> {when(r.created_at)}</strong><span>{r.error ?? (r.completed_at ? `Finished ${when(r.completed_at)}` : "")}</span></li>)}</ol>
          ) : <p className="op-muted">No runs recorded. Reminders and follow-ups are sent from the queue above rather than as runs.</p>}
          <h3 className="ao-h3">Changes</h3>
          {d.data.history.length ? (
            <ol className="ao-timeline">{d.data.history.map((h, i) => <li key={i}><strong>{words(h.action.replace(/^automation\./, ""))}</strong><span>{when(h.at)}{h.new?.reason ? ` — ${h.new.reason}` : ""}</span></li>)}</ol>
          ) : <p className="op-muted">No recorded changes.</p>}
          {d.data.can_manage ? (
            <div className="ao-drawer-actions">
              {a.status !== "active" && <button type="button" className="owner-primary-button" disabled={!a.business_live} title={a.business_live ? "" : "The business isn't live"} onClick={() => setChange("active")}>Resume</button>}
              {a.status === "active" && <button type="button" className="owner-secondary-button" onClick={() => setChange("paused")}>Pause</button>}
              {a.status !== "disabled" && <button type="button" className="bd-danger-button" onClick={() => setChange("disabled")}>Archive</button>}
            </div>
          ) : <p className="op-muted">Your admin role can see automations but not change them.</p>}
        </>
      )}
      {change && (
        <ReasonDialog title={`${VERB[change][0]} ${a.name}?`} icon={change === "active" ? "play_circle" : "pause_circle"} danger={change === "disabled"} confirmLabel={VERB[change][0]}
          onClose={() => setChange(null)}
          onConfirm={async (reason) => { await rpc("zella_admin_automation_set_status", { p_id: a.id, p_status: change, p_reason: reason }); d.reload(); onChanged(`${VERB[change][1]}.`); }}>
          <p>{change === "active" ? `${a.business_name}'s customers start getting these messages again (when sending is live).`
            : change === "paused" ? "It stops until resumed. Work already in the queue isn't sent while it's paused."
            : "It's switched off and kept for the record. It can be resumed later."}</p>
        </ReasonDialog>
      )}
    </Drawer>
  );
}

function Runs({ failed, me, options, say, onOpenBusiness }) {
  const [f, setF] = useState({ days: 30, status: failed ? "failed" : null, business: null, q: "", offset: 0 });
  const set = (k) => (v) => setF((x) => ({ ...x, [k]: v, offset: 0 }));
  const setQ = useCallback((v) => setF((x) => ({ ...x, q: v, offset: 0 })), []);
  const list = useLoad(() => rpc("zella_admin_runs", { p_status: f.status, p_business: f.business, p_q: f.q || null, p_from: since(f.days), p_to: null, p_limit: PAGE, p_offset: f.offset }), [f]);
  const [open, setOpen] = useState(null);
  return (
    <Panel>
      <Filters>
        <Search value={f.q} onChange={setQ} placeholder="Workflow or error" />
        <Select label="Period" value={String(f.days)} any={null} onChange={(v) => set("days")(Number(v))} options={PERIODS.map(([d, l]) => [String(d), l])} />
        {!failed && <Select label="Status" value={f.status} onChange={set("status")} options={[["running", "Running"], ["succeeded", "Succeeded"], ["failed", "Failed"], ["cancelled", "Cancelled"]]} />}
        <Select label="Business" value={f.business} onChange={set("business")} options={(options?.businesses ?? []).map((b) => [b.id, b.name])} />
      </Filters>
      <ErrorNote error={list.error} onRetry={list.reload} />
      <DataTable loading={list.loading} rows={list.data?.rows} rowKey={(r) => `${r.kind}-${r.id}`} onRow={setOpen}
        empty={failed ? "No failed runs in this period." : "No runs recorded in this period."}
        columns={[
          ["Started", (r) => when(r.started_at)], ["Workflow", (r) => <strong>{r.name}</strong>], ["Business", (r) => r.business_name ?? "Platform"],
          ["Status", (r) => <span className="ao-flags"><Pill tone={tone(r.status)}>{r.status}</Pill>{r.needs_manual && <Pill tone="warning">Needs a person</Pill>}</span>],
          ["Time", (r) => duration(r.duration_seconds)], ["Tries", (r) => r.attempts ?? 0],
          ["Error", (r) => (r.error ? `${r.failed_step ? `${r.failed_step}: ` : ""}${r.error}` : "—")],
        ]} />
      <Pager total={list.data?.total} offset={f.offset} onChange={(o) => setF((x) => ({ ...x, offset: o }))} />
      {open && <RunDrawer row={open} me={me} onClose={() => setOpen(null)} onOpenBusiness={onOpenBusiness} onChanged={(m) => { say(m); list.reload(); }} />}
    </Panel>
  );
}

function RunDrawer({ row, me, onClose, onOpenBusiness, onChanged }) {
  const d = useLoad(() => rpc("zella_admin_run_detail", { p_kind: row.kind, p_id: row.id }), [row.kind, row.id]);
  const [action, setAction] = useState(null);
  const r = d.data?.run;
  const manage = can(me, "integrations.manage");
  return (
    <Drawer title={r?.name ?? "Run"} icon="account_tree" onClose={onClose}>
      <ErrorNote error={d.error} onRetry={d.reload} />
      {!r ? <p className="op-muted">Loading…</p> : (
        <>
          <Facts rows={[["Business", r.business_id ? <button key="b" type="button" className="ao-link" onClick={() => onOpenBusiness(r.business_id)}>{r.business_name}</button> : "Platform"],
            ["Status", <Pill key="s" tone={tone(r.status)}>{r.status}</Pill>], r.version ? ["Workflow version", r.version] : null,
            ["Started", when(r.started_at)], ["Finished", when(r.finished_at)], ["Tries", r.attempts ?? 0],
            r.current_step ? ["Step", String(r.current_step)] : null, r.error_category ? ["Error type", words(r.error_category)] : null, r.error ? ["Error", r.error] : null,
            r.next_run_at ? ["Next try", when(r.next_run_at)] : null, r.providers_called?.length ? ["Providers called", r.providers_called.join(", ")] : null,
            r.correlation_id ? ["Correlation id", <code key="c">{r.correlation_id}</code>] : null]} />
          <h3 className="ao-h3">Steps</h3>
          {d.data.steps.length ? (
            <ol className="ao-timeline">{d.data.steps.map((s, i) => <li key={i}><strong><Pill tone={tone(s.status === "done" || s.status === "ok" ? "succeeded" : s.status)}>{s.status ?? "—"}</Pill> {s.name ?? `Step ${i + 1}`}</strong><span>{[s.at && when(s.at), s.error].filter(Boolean).join(" — ")}</span></li>)}</ol>
          ) : <p className="op-muted">No steps recorded.</p>}
          <p className="op-muted">Step inputs and outputs aren't shown: they can hold customer details.</p>
          {d.data.event && <><h3 className="ao-h3">Started by</h3><Facts rows={[["Event", words(d.data.event.type)], ["From", words(d.data.event.source)], ["Event status", words(d.data.event.status)],
            ["Received", when(d.data.event.received_at)], ["Event tries", d.data.event.attempts], d.data.event.error ? ["Event error", d.data.event.error] : null]} /></>}
          {d.data.dead_letter && <Facts rows={[["Dead letter", `${words(d.data.dead_letter.status)}${d.data.dead_letter.reason ? ` — ${d.data.dead_letter.reason}` : ""}`],
            d.data.dead_letter.resolved_at ? ["Reviewed", when(d.data.dead_letter.resolved_at)] : null]} />}
          <h3 className="ao-h3">Retry</h3>
          {d.data.retry.ok
            ? manage ? <p className="op-muted">The original event is replayed once; this run stays as it was.</p> : <p className="op-muted">An admin who manages integrations can retry it.</p>
            : <p className="op-muted">Can't retry: {d.data.retry.why}</p>}
          {manage && (
            <div className="ao-drawer-actions">
              {d.data.retry.ok && <button type="button" className="owner-primary-button" onClick={() => setAction("retry")}>Retry</button>}
              {row.kind === "workflow" && r.status === "failed" && (d.data.dead_letter?.status !== "resolved" || r.needs_manual) &&
                <button type="button" className="owner-secondary-button" onClick={() => setAction("review")}>Mark as reviewed</button>}
            </div>
          )}
        </>
      )}
      {action === "retry" && (
        <ReasonDialog title="Retry this run?" icon="replay" confirmLabel="Retry" onClose={() => setAction(null)}
          onConfirm={async (reason) => { await rpc("zella_admin_run_retry", { p_kind: row.kind, p_id: row.id, p_reason: reason }); d.reload(); onChanged("The event is back in the queue and runs once more on the next dispatch."); }}>
          <p>No step of this run succeeded and no provider was called, so replaying its event can't repeat a message. It runs on the next dispatch (if the scheduler is on).</p>
        </ReasonDialog>
      )}
      {action === "review" && (
        <ReasonDialog title="Mark this failure as reviewed?" icon="task_alt" confirmLabel="Mark reviewed" onClose={() => setAction(null)}
          onConfirm={async (note) => { await rpc("zella_admin_run_reviewed", { p_kind: row.kind, p_id: row.id, p_note: note }); d.reload(); onChanged("Marked as reviewed."); }}>
          <p>Its dead letter is closed and it no longer counts as needing a person. The run itself isn't changed or re-run.</p>
        </ReasonDialog>
      )}
    </Drawer>
  );
}

function Templates() {
  const [f, setF] = useState({ q: "", industry: null });
  const setQ = useCallback((v) => setF((x) => ({ ...x, q: v })), []);
  const list = useLoad(() => rpc("zella_admin_automation_templates", { p_q: f.q || null, p_industry: f.industry }), [f]);
  const [open, setOpen] = useState(null);
  const [offset, setOffset] = useState(0);
  const rows = list.data?.rows;
  return (
    <Panel description="The automations each industry's businesses start with. A business gets its own copy at setup; changing a copy never changes the template.">
      <Filters>
        <Search value={f.q} onChange={(v) => { setOffset(0); setQ(v); }} placeholder="Name or description" />
        <Select label="Industry" value={f.industry} onChange={(v) => { setOffset(0); setF((x) => ({ ...x, industry: v })); }} options={(list.data?.industries ?? []).map((i) => [i, words(i)])} />
      </Filters>
      <ErrorNote error={list.error} onRetry={list.reload} />
      <DataTable loading={list.loading} rows={rows?.slice(offset, offset + PAGE)} onRow={setOpen} empty="No templates match."
        columns={[["Template", (t) => <strong>{t.name}</strong>], ["Industry", (t) => words(t.industry_key)], ["Trigger", (t) => words(t.trigger_type)],
          ["Businesses using it", (t) => num(t.in_use)], ["Active", (t) => num(t.active)]]} />
      <Pager total={rows?.length} offset={offset} onChange={setOffset} />
      {open && (
        <Drawer title={open.name} icon="library_books" onClose={() => setOpen(null)}>
          <Facts rows={[["Industry", words(open.industry_key)], ["Trigger", words(open.trigger_type)], ["Description", open.description],
            ["Businesses using it", num(open.in_use)], ["Active copies", num(open.active)],
            ...Object.entries(open.settings ?? {}).filter(([, v]) => typeof v !== "object").map(([k, v]) => [words(k), String(v)])]} />
          <NotAvailable title="Templates are edited in the repository">They're seeded from the industry configuration (industry_automation_presets). Changing one here wouldn't reach businesses that already have their copy, so editing isn't offered.</NotAvailable>
        </Drawer>
      )}
    </Panel>
  );
}

function Infrastructure() {
  const h = useLoad(() => rpc("zella_admin_scheduler_health"), []);
  const s = h.data;
  return (
    <>
      <Panel title="Scheduled jobs" description="Jobs inside the database. They find due work and hand it to n8n." action={<button type="button" className="owner-secondary-button" onClick={h.reload}>Refresh</button>}>
        <ErrorNote error={h.error} onRetry={h.reload} />
        {s && <DataTable rows={s.jobs} rowKey={(j) => j.name} empty="No Zella jobs found."
          columns={[["Job", (j) => <code>{j.name}</code>], ["Schedule", (j) => <code>{j.schedule}</code>], ["State", (j) => <Pill tone={j.active ? "success" : "neutral"}>{j.active ? "Running" : "Off"}</Pill>],
            ["Last run", (j) => (j.last_run ? <span><Pill tone={j.last_run.status === "succeeded" ? "success" : "danger"}>{j.last_run.status}</Pill> {when(j.last_run.at)}</span> : "Never")],
            ["Last success", (j) => when(j.last_success)], ["Failures (24 h)", (j) => (j.failures_24h ? <Pill tone="danger">{j.failures_24h}</Pill> : 0)]]} />}
        <p className="op-muted">Jobs are switched on at go-live (n8n/GO-LIVE.md), not from this page, so a click can't start sending to customers.</p>
      </Panel>
      {s && (
        <Panel title="Queue">
          <div className="owner-stat-grid ao-stats">
            <Metric label="Reminders overdue (15 min+)" value={num(s.overdue.reminders)} tone={s.overdue.reminders ? "warning" : null} />
            <Metric label="Follow-ups overdue (15 min+)" value={num(s.overdue.followups)} tone={s.overdue.followups ? "warning" : null} />
            <Metric label="Events waiting (15 min+)" value={num(s.overdue.events)} tone={s.overdue.events ? "warning" : null} />
            <Metric label="Failed runs (24 h)" value={num(s.failed_24h.workflows)} tone={s.failed_24h.workflows ? "danger" : null} />
            <Metric label="Failed events (24 h)" value={num(s.failed_24h.events)} tone={s.failed_24h.events ? "danger" : null} />
          </div>
          <DataTable rows={s.dispatch} rowKey={(d) => d.workflow} empty="Nothing has been handed to n8n yet."
            columns={[["n8n workflow", (d) => words(d.workflow)], ["Last handed over", (d) => when(d.last_triggered_at)], ["Waiting then", (d) => num(d.waiting)],
              ["Total", (d) => num(d.total)], ["", (d) => d.stuck && <Pill tone="warning">Looks stuck</Pill>]]} />
        </Panel>
      )}
      <div className="zs ao-embed">
        <N8nConfig />
        <Webhooks />
      </div>
    </>
  );
}
