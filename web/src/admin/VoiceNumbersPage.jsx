import { useCallback, useState } from "react";
import { callOwnerFunction } from "../CreateBusinessWizard";
import { navigate } from "../router";
import { TelephonyProviders, VoiceCosts, VoiceUsage } from "../settings/AdminPanels";
import {
  AlertList, DataTable, Drawer, ErrorNote, Facts, Filters, Metric, NotAvailable, PAGE, PageHeader, Pager, Panel, PERIODS, Pill,
  ProviderHealth, ReasonDialog, Search, Select, Tabs, Toggle, can, duration, num, pct, rpc, since, useLoad, useOptions, useToast, when, words,
} from "./adminOps";

// Admin page: every business's phone numbers, its calls and its call routing, from the database (zella_admin_*
// functions in sql/zella_admin_ops.sql). Assigning and pausing numbers goes through the owner function, as before.
// Nothing here places a call or changes a Vapi assistant.

const TABS = [["overview", "Overview"], ["numbers", "Numbers"], ["calls", "Calls"], ["routing", "Call routing"], ["providers", "Providers & costs"]];
const CALL_STATUSES = ["initiated", "ringing", "answered", "completed", "missed", "failed"];
const OUTCOMES = ["resolved", "booked", "callback_needed", "left_message", "wrong_number", "spam", "other"];
const statusTone = (s) => (s === "completed" || s === "active" ? "success" : s === "failed" ? "danger" : s === "missed" || s === "paused" ? "warning" : "neutral");

export default function VoiceNumbersPage({ me, sub, onOpenBusiness }) {
  const tab = TABS.some(([k]) => k === sub) ? sub : "overview";
  const setTab = (k) => navigate(k === "overview" ? "/voice" : `/voice/${k}`);
  const [toast, say] = useToast();
  const options = useOptions();
  const [assign, setAssign] = useState(null);
  const [callFilter, setCallFilter] = useState(null);
  const manage = can(me, "telephony.manage");

  const openCalls = (filter) => { setCallFilter(filter); setTab("calls"); };
  return (
    <section className="owner-page ao-page">
      <PageHeader title="Voice & numbers" description="Every business's phone numbers, the calls the AI receptionist handled and who callers are put through to."
        actions={manage && <button type="button" className="owner-primary-button" onClick={() => setAssign({ e164: "", businessId: "", vapiPhoneNumberId: "", label: "" })}>Assign a number</button>} />
      <Tabs tabs={TABS} current={tab} onChange={setTab} />
      {tab === "overview" && <Overview onTab={setTab} onOpenCalls={openCalls} />}
      {tab === "numbers" && <Numbers me={me} options={options.data} onAssign={setAssign} onOpenCalls={openCalls} say={say} onOpenBusiness={onOpenBusiness} />}
      {tab === "calls" && <Calls me={me} options={options.data} initial={callFilter} onOpenBusiness={onOpenBusiness} />}
      {tab === "routing" && <Routing me={me} options={options.data} say={say} />}
      {tab === "providers" && <Providers me={me} />}
      {assign && <AssignDialog edit={assign} options={options.data} onClose={() => setAssign(null)} onDone={(m) => { say(m); setTab("numbers"); }} />}
      {toast}
    </section>
  );
}

function Overview({ onTab, onOpenCalls }) {
  const [days, setDays] = useState(30);
  const data = useLoad(() => rpc("zella_admin_voice_overview", { p_from: since(days), p_to: null }), [days]);
  const alerts = useLoad(() => rpc("zella_admin_voice_alerts"), []);
  const o = data.data;
  return (
    <>
      <Filters>
        <Select label="Period" value={String(days)} any={null} onChange={(v) => setDays(Number(v))} options={PERIODS.map(([d, l]) => [String(d), l])} />
        <button type="button" className="owner-secondary-button" onClick={() => { data.reload(); alerts.reload(); }}>Refresh</button>
      </Filters>
      <ErrorNote error={data.error} onRetry={data.reload} />
      {o && (
        <>
          {!o.calls_live && <NotAvailable title="Outbound AI calls are off">The calls_live switch is off, so Zella places no outbound calls. Inbound calls are answered by each business's receptionist once its number is linked in Vapi.</NotAvailable>}
          <div className="owner-stat-grid ao-stats">
            <Metric label="Active numbers" value={num(o.numbers_active)} note={o.numbers_paused ? `${o.numbers_paused} paused` : "None paused"} />
            <Metric label="Inbound calls" value={num(o.inbound)} note={`Answer rate ${pct(o.answer_rate)}`} />
            <Metric label="Outbound calls" value={num(o.outbound)} />
            <Metric label="In progress now" value={num(o.in_progress)} />
            <Metric label="Completed" value={num(o.completed)} note={`Average ${duration(o.avg_seconds)}`} />
            <Metric label="Missed" value={num(o.missed)} tone={o.missed ? "warning" : null} />
            <Metric label="Failed" value={num(o.failed)} tone={o.failed ? "danger" : null} />
            <Metric label="Transfers that didn't connect" value={num(o.transfers_failed)} tone={o.transfers_failed ? "warning" : null} />
          </div>
          {o.numbers_active === 0 && (
            <NotAvailable title="No phone numbers yet">Numbers bought in Telnyx or Vapi are assigned to a business with "Assign a number". Until then no calls can reach Zella.</NotAvailable>
          )}
          {o.numbers_without_vapi > 0 && (
            <NotAvailable title={`${o.numbers_without_vapi} active number${o.numbers_without_vapi === 1 ? "" : "s"} not linked to Vapi`}>Add the Vapi phone number id under Numbers so calls are matched to the business.</NotAvailable>
          )}
        </>
      )}
      <div className="ao-two">
        <Panel title="Needs attention" description="From provider checks, numbers and the last 24 hours of calls.">
          <ErrorNote error={alerts.error} onRetry={alerts.reload} />
          <AlertList alerts={alerts.data} onOpen={(a) => (a.link === "calls" ? onOpenCalls({ business: a.business_id ?? null, failedOnly: a.kind !== "call_volume_spike" }) : onTab(a.link))} />
        </Panel>
        <Panel title="Providers" action={<button type="button" className="owner-secondary-button" onClick={() => onTab("providers")}>Details</button>}>
          {o && <ProviderHealth rows={o.providers} checksLive={o.checks_live} names={[["vapi", "Vapi", "AI voice and phone numbers"], ["telnyx", "Telnyx", "Numbers and carrier"]]} />}
        </Panel>
      </div>
    </>
  );
}

function Numbers({ me, options, onAssign, onOpenCalls, say, onOpenBusiness }) {
  const [f, setF] = useState({ q: "", status: null, business: null, offset: 0 });
  const set = (k) => (v) => setF((x) => ({ ...x, [k]: v, offset: 0 }));
  const setQ = useCallback((v) => setF((x) => ({ ...x, q: v, offset: 0 })), []);
  const list = useLoad(() => rpc("zella_admin_numbers", { p_q: f.q || null, p_status: f.status, p_business: f.business, p_limit: PAGE, p_offset: f.offset }), [f]);
  const [open, setOpen] = useState(null);
  const [action, setAction] = useState(null);
  const manage = can(me, "telephony.manage");
  const done = (m) => { say(m); setOpen(null); list.reload(); };

  return (
    <Panel>
      <Filters>
        <Search value={f.q} onChange={setQ} placeholder="Number, business or label" />
        <Select label="Status" value={f.status} onChange={set("status")} options={[["active", "Active"], ["paused", "Paused"]]} />
        <Select label="Business" value={f.business} onChange={set("business")} options={(options?.businesses ?? []).map((b) => [b.id, b.name])} />
      </Filters>
      <ErrorNote error={list.error} onRetry={list.reload} />
      <DataTable loading={list.loading} rows={list.data?.rows} onRow={setOpen}
        empty={f.q || f.status || f.business ? "No numbers match these filters." : "No phone numbers are assigned to any business yet."}
        columns={[
          ["Number", (r) => <strong>{r.e164}</strong>], ["Business", (r) => r.business_name], ["Label", (r) => r.label ?? "—"],
          ["Receptionist", (r) => r.agent?.name ?? <Pill tone="warning">None</Pill>],
          ["Vapi", (r) => (r.vapi_linked ? <Pill tone="success">Linked</Pill> : <Pill tone="warning">Not linked</Pill>)],
          ["Status", (r) => <Pill tone={statusTone(r.status)}>{r.status}</Pill>], ["Calls (30 days)", (r) => num(r.calls_30d)], ["Last call", (r) => when(r.last_call_at)],
        ]} />
      <Pager total={list.data?.total} offset={f.offset} onChange={(o) => setF((x) => ({ ...x, offset: o }))} />

      {open && (
        <Drawer title={open.e164} icon="call" onClose={() => setOpen(null)}>
          <Facts rows={[["Business", <button key="b" type="button" className="ao-link" onClick={() => onOpenBusiness(open.business_id)}>{open.business_name}</button>],
            ["Business state", words(open.business_state)], ["Label", open.label], ["Country code", open.country_code], ["Status", <Pill key="s" tone={statusTone(open.status)}>{open.status}</Pill>],
            ["Receptionist", open.agent ? `${open.agent.name} (${words(open.agent.status)})` : "None — calls can't be answered"],
            ["Vapi phone number id", open.vapi_phone_number_id ? <code key="v">{open.vapi_phone_number_id}</code> : "Not linked"],
            ["Calls, last 30 days", num(open.calls_30d)], ["Last call", when(open.last_call_at)], ["Added", when(open.created_at)]]} />
          <NotAvailable title="Carrier details aren't read from Telnyx">Number type, capabilities and carrier status need the Telnyx API from a server action, which isn't built. Buying and releasing numbers at the carrier is done in the Telnyx or Vapi dashboard.</NotAvailable>
          <div className="ao-drawer-actions">
            <button type="button" className="owner-secondary-button" onClick={() => onOpenCalls({ business: open.business_id, q: open.e164.replace(/\D/g, "").slice(-7) })}>View calls</button>
            {manage && <>
              <button type="button" className="owner-secondary-button" onClick={() => onAssign({ id: open.id, e164: open.e164, businessId: open.business_id, vapiPhoneNumberId: open.vapi_phone_number_id ?? "", label: open.label ?? "" })}>Reassign or edit</button>
              <button type="button" className="owner-secondary-button" onClick={() => setAction({ kind: "status", row: open })}>{open.status === "active" ? "Pause" : "Activate"}</button>
              {open.status === "paused" && <button type="button" className="bd-danger-button" onClick={() => setAction({ kind: "release", row: open })}>Release from Zella</button>}
            </>}
          </div>
          {!manage && <p className="op-muted">Your admin role can see numbers but not change them.</p>}
        </Drawer>
      )}
      {action?.kind === "status" && (
        <ReasonDialog title={action.row.status === "active" ? `Pause ${action.row.e164}?` : `Activate ${action.row.e164}?`} icon="pause_circle" danger={action.row.status === "active"}
          confirmLabel={action.row.status === "active" ? "Pause" : "Activate"} onClose={() => setAction(null)}
          onConfirm={async (reason) => {
            await callOwnerFunction("number_set_status", { id: action.row.id, status: action.row.status === "active" ? "paused" : "active", reason });
            done(action.row.status === "active" ? "Number paused." : "Number activated.");
          }}>
          {action.row.status === "active"
            ? <p>Zella stops treating this as {action.row.business_name}'s number. It stays with the carrier; calls to it will no longer be matched to the business.</p>
            : <p>The business's plan must include another number.</p>}
        </ReasonDialog>
      )}
      {action?.kind === "release" && (
        <ReasonDialog title={`Release ${action.row.e164} from Zella?`} icon="delete" danger word="RELEASE" confirmLabel="Release" onClose={() => setAction(null)}
          onConfirm={async (reason) => { await rpc("zella_admin_number_release", { p_id: action.row.id, p_reason: reason }); done(`${action.row.e164} released from Zella.`); }}>
          <p>The number is removed from {action.row.business_name}. Its past calls are kept. This doesn't cancel it at the carrier — do that in the Telnyx or Vapi dashboard, or it keeps costing money.</p>
        </ReasonDialog>
      )}
    </Panel>
  );
}

function AssignDialog({ edit: initial, options, onClose, onDone }) {
  const [edit, setEdit] = useState(initial);
  const field = (k) => (e) => setEdit({ ...edit, [k]: e.target.value });
  return (
    <ReasonDialog title={initial.id ? `Edit ${initial.e164}` : "Assign a number"} icon="add_call" confirmLabel="Save" onClose={onClose}
      onConfirm={async (reason) => {
        if (!/^\+[1-9]\d{6,14}$/.test(edit.e164.replace(/[\s()-]/g, ""))) throw new Error("Enter the number with its country code, like +15551234567.");
        if (!edit.businessId) throw new Error("Choose a business.");
        await callOwnerFunction("number_assign", { ...edit, e164: edit.e164.replace(/[\s()-]/g, ""), reason });
        onDone(initial.id ? "Number updated." : "Number assigned.");
      }}>
      <div className="ao-form">
        <label className="owner-field"><span>Number (with country code)</span><input value={edit.e164} onChange={field("e164")} disabled={Boolean(initial.id)} placeholder="+15551234567" /></label>
        <label className="owner-field"><span>Business</span>
          <select value={edit.businessId} onChange={field("businessId")}>
            <option value="">Choose…</option>
            {(options?.businesses ?? []).filter((b) => b.state !== "cancelled").map((b) => <option key={b.id} value={b.id}>{b.name}{b.state !== "active" ? ` (${words(b.state)})` : ""}</option>)}
          </select>
        </label>
        <label className="owner-field"><span>Vapi phone number id</span><input value={edit.vapiPhoneNumberId} onChange={field("vapiPhoneNumberId")} placeholder="From the Vapi dashboard" /></label>
        <label className="owner-field"><span>Label</span><input value={edit.label} onChange={field("label")} placeholder="Main line" /></label>
      </div>
      <p className="op-muted">The number must already be bought in Telnyx or Vapi; Zella doesn't buy numbers.{initial.id ? " Calls reach the new business's receptionist once Vapi points at it." : ""}</p>
    </ReasonDialog>
  );
}

function Calls({ me, options, initial, onOpenBusiness }) {
  const [f, setF] = useState({ days: 30, business: initial?.business ?? null, direction: null, status: null, outcome: null, failedOnly: Boolean(initial?.failedOnly), q: initial?.q ?? "", offset: 0 });
  const set = (k) => (v) => setF((x) => ({ ...x, [k]: v, offset: 0 }));
  const setQ = useCallback((v) => setF((x) => ({ ...x, q: v, offset: 0 })), []);
  const list = useLoad(() => rpc("zella_admin_calls", {
    p_from: since(f.days), p_to: null, p_business: f.business, p_direction: f.direction, p_status: f.status, p_outcome: f.outcome,
    p_failed_only: f.failedOnly, p_q: f.q || null, p_limit: PAGE, p_offset: f.offset,
  }), [f]);
  const [open, setOpen] = useState(null);
  return (
    <Panel>
      <Filters>
        <Search label="Caller or number" value={f.q} onChange={setQ} placeholder="At least 4 digits" />
        <Select label="Period" value={String(f.days)} any={null} onChange={(v) => set("days")(Number(v))} options={PERIODS.map(([d, l]) => [String(d), l])} />
        <Select label="Business" value={f.business} onChange={set("business")} options={(options?.businesses ?? []).map((b) => [b.id, b.name])} />
        <Select label="Direction" value={f.direction} onChange={set("direction")} options={[["inbound", "Inbound"], ["outbound", "Outbound"]]} />
        <Select label="Status" value={f.status} onChange={set("status")} options={CALL_STATUSES.map((s) => [s, words(s)])} />
        <Select label="Outcome" value={f.outcome} onChange={set("outcome")} options={OUTCOMES.map((s) => [s, words(s)])} />
        <Toggle label="Problems only" checked={f.failedOnly} onChange={set("failedOnly")} />
      </Filters>
      <ErrorNote error={list.error} onRetry={list.reload} />
      <DataTable loading={list.loading} rows={list.data?.rows} onRow={(r) => setOpen(r.id)} empty="No calls in this period match these filters."
        columns={[
          ["When", (r) => when(r.created_at)], ["Business", (r) => r.business_name], ["Direction", (r) => words(r.direction)], ["Caller", (r) => r.caller ?? "Unknown"],
          ["Number", (r) => r.number ?? "—"], ["Status", (r) => <Pill tone={statusTone(r.status)}>{r.status}</Pill>], ["Length", (r) => duration(r.duration_seconds)],
          ["Outcome", (r) => (r.outcome ? words(r.outcome) : "—")],
          ["", (r) => <span className="ao-flags">{r.needs_human && <Pill tone="warning">Needs a person</Pill>}{r.failure_reason && <Pill tone="danger">Error</Pill>}
            {["failed", "no_one_available"].includes(r.transfer_status) && <Pill tone="warning">Transfer failed</Pill>}</span>],
        ]} />
      <Pager total={list.data?.total} offset={f.offset} onChange={(o) => setF((x) => ({ ...x, offset: o }))} />
      {open && <CallDrawer id={open} me={me} onClose={() => setOpen(null)} onOpenBusiness={onOpenBusiness} />}
    </Panel>
  );
}

function CallDrawer({ id, onClose, onOpenBusiness }) {
  const [withContent, setWithContent] = useState(false);
  const d = useLoad(() => rpc("zella_admin_call_detail", { p_call_id: id, p_with_content: withContent }), [id, withContent]);
  const c = d.data?.call;
  return (
    <Drawer title="Call details" icon="call" onClose={onClose}>
      <ErrorNote error={d.error} onRetry={d.reload} />
      {!c ? <p className="op-muted">Loading…</p> : (
        <>
          <Facts rows={[["Business", <button key="b" type="button" className="ao-link" onClick={() => onOpenBusiness(c.business_id)}>{c.business_name}</button>],
            ["Direction", words(c.direction)], ["From", c.from], ["To", c.to], ["Status", <Pill key="s" tone={statusTone(c.status)}>{c.status}</Pill>],
            ["Answered by AI", c.ai_handled ? "Yes" : "No"], ["Outcome", c.outcome ? words(c.outcome) : null], ["Outcome note", c.outcome_note],
            ["Transfer", c.transfer_status ? words(c.transfer_status) : null], ["Length", duration(c.duration_seconds)],
            c.needs_human ? ["Needs a person", c.escalation_reason ?? "Yes"] : null, c.escalation_resolved_at ? ["Resolved", when(c.escalation_resolved_at)] : null,
            c.failure_reason ? ["Error", c.failure_reason] : null, ["Provider call id", c.provider_call_id ? <code key="p">{c.provider_call_id}</code> : null]]} />
          <h3 className="ao-h3">Timeline</h3>
          <ol className="ao-timeline">
            {[["Created", c.created_at], ["Started", c.started_at], ["Answered", c.answered_at], ["Escalated", c.escalated_at], ["Ended", c.ended_at]]
              .filter(([, t]) => t).map(([l, t]) => <li key={l}><strong>{l}</strong><span>{when(t)}</span></li>)}
            {d.data.tools.map((t, i) => <li key={`t${i}`}><strong>Tool: {words(t.tool)}</strong><span>{words(t.status)}{t.error ? ` — ${t.error}` : ""} · {when(t.at)}</span></li>)}
            {d.data.messages.map((m, i) => <li key={`m${i}`}><strong>Message taken ({words(m.kind)})</strong><span>{words(m.status)} · {when(m.at)}</span></li>)}
            {d.data.callbacks.map((k, i) => <li key={`k${i}`}><strong>Callback</strong><span>{words(k.status)}{k.due_at ? ` · due ${when(k.due_at)}` : ""}</span></li>)}
          </ol>
          {d.data.usage.length > 0 && <Facts rows={d.data.usage.map((u, i) => [`Usage ${i + 1}`, `${words(u.kind)}: ${u.billable_seconds ?? 0} s (${words(u.status)})`])} />}
          <h3 className="ao-h3">Summary, transcript and recording</h3>
          {!c.has_transcript && !c.has_recording ? <p className="op-muted">None stored for this call.</p>
            : !d.data.content_allowed ? <p className="op-muted">Your admin role can't open call content.</p>
            : !d.data.content ? (
              <button type="button" className="owner-secondary-button" onClick={() => setWithContent(true)}>Show (this is recorded in the audit log)</button>
            ) : (
              <div className="ao-content">
                {d.data.content.summary && <p><strong>Summary:</strong> {d.data.content.summary}</p>}
                {d.data.content.recording_url && <audio controls preload="none" src={d.data.content.recording_url} />}
                {d.data.content.transcript && <pre className="ao-pre">{d.data.content.transcript}</pre>}
              </div>
            )}
        </>
      )}
    </Drawer>
  );
}

function Routing({ me, options, say }) {
  const [business, setBusiness] = useState(null);
  const manage = can(me, "telephony.manage");
  return (
    <Panel title="Call routing" description="Who the AI receptionist puts a caller through to when they ask for a person. The same rules the receptionist reads on every call.">
      <Filters>
        <Select label="Business" value={business} any="Choose a business…" onChange={setBusiness} options={(options?.businesses ?? []).map((b) => [b.id, b.name])} />
      </Filters>
      {!business ? <div className="op-empty">Choose a business to see and change its call routing.</div>
        : <RoutingForm key={business} businessId={business} manage={manage} say={say} />}
    </Panel>
  );
}

function RoutingForm({ businessId, manage, say }) {
  const d = useLoad(() => rpc("zella_admin_routing_get", { p_business_id: businessId }), [businessId]);
  const [form, setForm] = useState(null);
  const [confirm, setConfirm] = useState(false);
  if (d.error) return <ErrorNote error={d.error} onRetry={d.reload} />;
  if (!d.data) return <p className="op-muted">Loading…</p>;
  const r = d.data;
  if (!r.has_agent) return <NotAvailable title="No AI receptionist">This business has no receptionist yet, so calls aren't answered and there is no routing to change.</NotAvailable>;
  const base = { transfer_enabled: r.transfer_enabled, transfer_number: r.transfer_number ?? "", fallback_number: r.fallback_number ?? "", transfer_route: r.transfer_route, transfer_open_hours_only: r.transfer_open_hours_only };
  const v = form ?? base;
  const set = (k, val) => setForm({ ...v, [k]: val });
  const changes = Object.keys(base).filter((k) => String(base[k]) !== String(v[k]));
  const label = { transfer_enabled: "Put callers through to a person", transfer_number: "Transfer number", fallback_number: "Fallback number", transfer_route: "Route to", transfer_open_hours_only: "Only during opening hours" };
  const show = (k, val) => (typeof val === "boolean" ? (val ? "Yes" : "No") : k === "transfer_route" ? (val === "fallback" ? "Fallback number" : "Transfer number") : val || "None");
  return (
    <>
      <div className="ao-form">
        <label className="ao-filter ao-check"><input type="checkbox" checked={v.transfer_enabled} disabled={!manage} onChange={(e) => set("transfer_enabled", e.target.checked)} /><span>{label.transfer_enabled}</span></label>
        <label className="owner-field"><span>Transfer number</span><input value={v.transfer_number} disabled={!manage} onChange={(e) => set("transfer_number", e.target.value)} placeholder="+15551234567" /></label>
        <label className="owner-field"><span>Fallback number</span><input value={v.fallback_number} disabled={!manage} onChange={(e) => set("fallback_number", e.target.value)} placeholder="Used if routed to fallback" /></label>
        <label className="owner-field"><span>Route to</span>
          <select value={v.transfer_route} disabled={!manage} onChange={(e) => set("transfer_route", e.target.value)}><option value="primary">Transfer number</option><option value="fallback">Fallback number</option></select>
        </label>
        <label className="ao-filter ao-check"><input type="checkbox" checked={v.transfer_open_hours_only} disabled={!manage} onChange={(e) => set("transfer_open_hours_only", e.target.checked)} /><span>{label.transfer_open_hours_only}</span></label>
      </div>
      <Facts rows={[["Time zone", r.timezone], ["Opening hours set", r.has_hours ? "Yes" : "No — outside-hours rules can't apply"],
        ["On-call rota", r.on_call?.enabled ? `On (${words(r.on_call.scope)})` : "Off"]]} />
      {manage ? (
        <div className="ao-drawer-actions">
          <button type="button" className="owner-secondary-button" disabled={!changes.length} onClick={() => setForm(null)}>Undo changes</button>
          <button type="button" className="owner-primary-button" disabled={!changes.length} onClick={() => setConfirm(true)}>Review and save</button>
        </div>
      ) : <p className="op-muted">Your admin role can see routing but not change it.</p>}
      {confirm && (
        <ReasonDialog title="Save call routing?" icon="alt_route" confirmLabel="Save" onClose={() => setConfirm(false)}
          onConfirm={async (reason) => {
            await rpc("zella_admin_routing_save", { p_business_id: businessId, p_rules: v, p_reason: reason });
            setForm(null); d.reload(); say("Call routing saved. The receptionist uses it from the next call.");
          }}>
          <table className="owner-table ao-table ao-diff"><thead><tr><th>Setting</th><th>Now</th><th>After</th></tr></thead>
            <tbody>{changes.map((k) => <tr key={k}><td>{label[k]}</td><td>{show(k, base[k])}</td><td><strong>{show(k, v[k])}</strong></td></tr>)}</tbody></table>
        </ReasonDialog>
      )}
    </>
  );
}

function Providers({ me }) {
  const data = useLoad(() => rpc("zella_admin_voice_overview", { p_from: since(1), p_to: null }), []);
  return (
    <>
      <Panel title="Connection checks" description="Zella's own checks of each provider, run by the provider health job.">
        <ErrorNote error={data.error} onRetry={data.reload} />
        {data.data && <ProviderHealth rows={data.data.providers} checksLive={data.data.checks_live} names={[["vapi", "Vapi", "AI voice and phone numbers"], ["telnyx", "Telnyx", "Numbers and carrier"]]} />}
        {data.data && !data.data.checks_live && <NotAvailable title="Provider checks are off">The provider health job isn't switched on, so connection status is unknown rather than healthy. A "test connection" button isn't offered because it would need the provider keys in the browser.</NotAvailable>}
      </Panel>
      <div className="zs ao-embed">
        <TelephonyProviders />
        <VoiceUsage />
        <VoiceCosts me={me} />
      </div>
    </>
  );
}
