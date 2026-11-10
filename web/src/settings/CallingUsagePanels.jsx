import { useState } from "react";
import { supabase } from "../supabase";
import { friendly } from "../BusinessShared";
import { Banner, Card, Confirm, Facts, Field, LoadState, Pill, Table, useAsync, when, words } from "./SettingsKit";

// Calling usage, read from the usage ledger (sql/zella_call_usage.sql). The database checks who may see what:
// a business sees only its own records; admins need billing.view (and billing.manage to retry).
// No plan, allowance, remaining minutes or charges are shown unless a subscription plan really defines them.

async function rpc(name, args) {
  const { data, error } = await supabase.rpc(name, args);
  if (error) throw new Error(error.message?.includes("NOT_ALLOWED") ? "Your role can't see calling usage." : friendly(error));
  return data;
}
const PAGE = 25;
const day = (d) => d.toISOString().slice(0, 10);
const startOf = (s) => new Date(`${s}T00:00:00`);
const endOf = (s) => new Date(new Date(`${s}T00:00:00`).getTime() + 86400000);
const mins = (m) => (m == null ? "—" : `${Number(m).toLocaleString(undefined, { maximumFractionDigits: 2 })} min`);
const secs = (s) => {
  if (s == null) return "—";
  const v = Math.abs(Number(s)); const h = Math.floor(v / 3600); const m = Math.floor((v % 3600) / 60); const r = v % 60;
  return `${s < 0 ? "−" : ""}${h ? `${h} h ` : ""}${m || h ? `${m} min ` : ""}${r} s`;
};
const CATEGORY = { inbound_ai: "Inbound AI calls", outbound_ai: "Outbound AI calls", other_ai: "Other AI calls" };

function useRange() {
  const now = new Date();
  const [from, setFrom] = useState(day(new Date(now.getTime() - 29 * 86400000)));
  const [to, setTo] = useState(day(now));
  const ok = from && to && from <= to;
  const picker = (
    <div className="zs-grid" style={{ display: "flex", gap: 12, flexWrap: "wrap", marginBottom: 12 }}>
      <Field label="From"><input type="date" value={from} max={to} onChange={(e) => setFrom(e.target.value)} /></Field>
      <Field label="To"><input type="date" value={to} min={from} onChange={(e) => setTo(e.target.value)} /></Field>
    </div>
  );
  return { from, to, ok, picker, range: ok ? { p_from: startOf(from).toISOString(), p_to: endOf(to).toISOString() } : null };
}

function Pager({ page, total, onPage }) {
  const pages = Math.max(1, Math.ceil((total ?? 0) / PAGE));
  if (pages <= 1) return null;
  return (
    <div style={{ display: "flex", gap: 8, alignItems: "center", marginTop: 10 }}>
      <button type="button" className="zs-btn" disabled={page === 0} onClick={() => onPage(page - 1)}>Previous</button>
      <span className="zs-muted">Page {page + 1} of {pages}</span>
      <button type="button" className="zs-btn" disabled={page + 1 >= pages} onClick={() => onPage(page + 1)}>Next</button>
    </div>
  );
}

function Allowance({ a }) {
  if (!a?.configured) {
    return <Banner>Usage allowance will appear here when your subscription plan is configured.</Banner>;
  }
  return (
    <Facts rows={[["Included this period", mins(a.included_minutes)], ["Used", mins(a.consumed_minutes)], ["Remaining", mins(a.remaining_minutes)],
      ["Used so far", a.percent_used == null ? "—" : `${a.percent_used}%`], ["Period", `${when(a.period_from)} to ${when(a.period_to)}`],
      ["Allowance", a.exhausted ? <Pill tone="warning">Used up</Pill> : <Pill tone="success">Available</Pill>]]} />
  );
}

/* ---------------- CRM: Settings > Billing > Calling usage ---------------- */

export function BusinessCallingUsage({ w }) {
  const r = useRange();
  const [page, setPage] = useState(0);
  const summary = useAsync(() => (r.range ? rpc("zella_call_usage_summary", { p_business_id: w.id, ...r.range }) : Promise.resolve(null)), [w.id, r.from, r.to]);
  const rows = useAsync(() => (r.range ? rpc("zella_call_usage_records", { p_business_id: w.id, ...r.range, p_limit: PAGE, p_offset: page * PAGE }) : Promise.resolve(null)), [w.id, r.from, r.to, page]);
  return (
    <>
      <Card title="Calling usage" sub="AI call time from your call records, counted once per call. Times are shown in your browser's time zone.">
        {r.picker}
        {!r.ok ? <Banner tone="warn">Choose a start date on or before the end date.</Banner> : (
          <LoadState state={summary}>{(s) => s && (
            <>
              <Facts rows={[["Calls counted", s.totals?.calls ?? 0], ["Call time", secs(s.totals?.duration_seconds)], ["Usage", mins(s.totals?.usage_minutes)],
                ["Corrections", s.totals?.adjustments?.count ? `${s.totals.adjustments.count} (${mins(s.totals.adjustments.minutes)})` : "None"],
                ["Waiting to be counted", s.pending ? `${s.pending} call(s): their final length hasn't arrived yet` : "None"],
                ["Needs attention", (s.issues?.open ?? 0) + (s.issues?.escalated ?? 0) ? `${(s.issues?.open ?? 0) + (s.issues?.escalated ?? 0)} call(s) the Zella team is checking` : "None"],
                ["Last updated", when(s.totals?.last_processed_at) || "Not yet"]]} />
              {Object.keys(s.totals?.by_category ?? {}).length > 0 && (
                <Table rowKey={(x) => x[0]} rows={Object.entries(s.totals.by_category)} columns={[["Kind", (x) => CATEGORY[x[0]] ?? words(x[0])], ["Calls", (x) => x[1].calls], ["Usage", (x) => mins(x[1].minutes)]]} />
              )}
            </>
          )}</LoadState>
        )}
      </Card>
      <Card title="Your allowance">
        <LoadState state={summary}>{(s) => <Allowance a={s?.allowance} />}</LoadState>
      </Card>
      <Card title="Usage history" sub="Newest first. Caller numbers show only the last four digits.">
        {r.ok && (
          <LoadState state={rows}>{(d) => d && (
            <>
              <Table rows={d.rows} empty="No calls counted in these dates." columns={[
                ["When", (x) => when(x.occurred_at)], ["Kind", (x) => (x.kind === "adjustment" ? "Correction" : CATEGORY[x.category] ?? words(x.category))],
                ["Caller", (x) => x.caller ?? "—"], ["Call time", (x) => secs(x.duration_seconds)], ["Usage", (x) => mins(x.minutes)],
                ["Status", (x) => (x.reconciliation === "adjusted" ? <Pill tone="info">Corrected</Pill> : <Pill tone="success">Counted</Pill>)]]} />
              <Pager page={page} total={d.total} onPage={setPage} />
            </>
          )}</LoadState>
        )}
      </Card>
    </>
  );
}

/* ---------------- Admin: Settings > Billing > Calling usage ---------------- */

export function AdminCallingUsage() {
  const r = useRange();
  const [biz, setBiz] = useState("");
  const [page, setPage] = useState(0);
  const [retry, setRetry] = useState(null);
  const [notice, setNotice] = useState("");
  const state = useAsync(() => (r.range ? rpc("zella_admin_call_usage", { p_business_id: biz || null, ...r.range, p_limit: PAGE, p_offset: page * PAGE }) : Promise.resolve(null)),
    [biz, r.from, r.to, page]);
  const businesses = Object.values(Object.fromEntries((state.data?.records ?? []).concat(state.data?.issues ?? []).filter((x) => x.business_id).map((x) => [x.business_id, { id: x.business_id, name: x.business }])));
  return (
    <>
      {notice && <Banner tone="success">{notice}</Banner>}
      <Card title="Calling usage" sub="The usage ledger for every business. Read only unless your role has billing.manage.">
        {r.picker}
        <Field label="Business"><select value={biz} onChange={(e) => { setBiz(e.target.value); setPage(0); }}>
          <option value="">All businesses</option>{businesses.map((b) => <option key={b.id} value={b.id}>{b.name}</option>)}</select></Field>
      </Card>
      <LoadState state={state}>{(d) => d && (
        <>
          <Card title="Usage records">
            <Table rows={d.records} empty="No usage in these dates." columns={[["When", (x) => when(x.occurred_at)], ["Business", (x) => x.business], ["Kind", (x) => words(x.kind)],
              ["Category", (x) => words(x.category)], ["Call time", (x) => secs(x.duration_seconds)], ["Billable", (x) => secs(x.billable_seconds)], ["Usage", (x) => mins(x.minutes)],
              ["Provider call", (x) => <code>{x.provider_call_id}</code>], ["Recorded by", (x) => words(x.processed_by)]]} />
            <Pager page={page} total={(page + 1) * PAGE + (d.records.length === PAGE ? 1 : 0)} onPage={setPage} />
          </Card>
          <Card title="Processing issues and discrepancies" sub="Missing or implausible durations, failures and ledger mismatches. Nothing is estimated: these calls are not counted until fixed.">
            <Table rows={d.issues} empty="No open issues." columns={[["Since", (x) => when(x.created_at)], ["Business", (x) => x.business ?? "—"], ["Issue", (x) => words(x.kind)],
              ["Status", (x) => <Pill tone={x.status === "escalated" ? "warning" : ""}>{words(x.status)}</Pill>], ["Attempts", (x) => x.attempts], ["Detail", (x) => x.last_error ?? "—"],
              ["", (x) => (d.can_retry ? <button type="button" className="zs-btn" onClick={() => setRetry(x)}>Retry</button> : null)]]} />
          </Card>
          <Card title="Threshold events" sub="One per business, threshold and billing period. Delivery is handled by the notification workflows.">
            <Table rows={d.threshold_events} empty="No thresholds reached. Thresholds apply only when a plan defines a minute allowance." columns={[
              ["When", (x) => when(x.created_at)], ["Business", (x) => x.business], ["Event", (x) => words(x.event_type)], ["Usage", (x) => `${mins(x.usage_minutes)} of ${mins(x.limit_minutes)}`],
              ["Notice delivery", (x) => <Pill tone={x.delivery_status === "failed" ? "danger" : x.delivery_status === "sent" ? "success" : ""}>{words(x.delivery_status ?? "pending")}</Pill>],
              ["Error", (x) => x.delivery_error ?? "—"]]} />
          </Card>
          <Card title="Policy and audit">
            <Facts rows={[["Rounding", `${d.policy.increment_seconds === 1 ? "Exact seconds" : `${d.policy.increment_seconds} s steps`}, ${d.policy.rounding}`],
              ["Minimum per call", d.policy.minimum_billable_seconds ? `${d.policy.minimum_billable_seconds} s` : "None"],
              ["Calls not counted", d.policy.ignore_under_seconds ? `Shorter than ${d.policy.ignore_under_seconds} s` : "None"]]} />
            <Table rowKey={(x) => `${x.at}${x.action}`} rows={d.audit} empty="No usage actions recorded yet." columns={[["When", (x) => when(x.at)], ["Action", (x) => words(x.action)], ["By", (x) => <code>{x.user_id}</code>]]} />
          </Card>
        </>
      )}</LoadState>
      {retry && (
        <Confirm title="Retry this call's usage?" confirmLabel="Retry" onClose={() => setRetry(null)} onConfirm={async () => {
          const res = await rpc("zella_admin_retry_usage", { p_issue_id: retry.id });
          setNotice(`Retried: ${words(res?.result ?? "done")}. This was recorded in the audit log.`); setRetry(null); state.reload();
        }}>It processes the call again from its stored record. A call still missing its duration stays uncounted.</Confirm>
      )}
    </>
  );
}
