import { useState } from "react";
import { DISPUTE_STATUS, INVOICE_STATUS, REFUND_KIND, REFUND_STATUS, usd } from "./billingRecords";
import { DataTable, ErrorNote, Filters, Panel, Pill, Select, Tabs, can, rpc, useLoad, when } from "./adminOps";

// Admin > Plans & subscriptions: what Stripe charged and refunded, as Zella Voice recorded it from verified Stripe
// events (docs/PAYMENTS_ARCHITECTURE.md §6.7, §6.8, §6.11). Read only, except the Zella Voice owner's refund decision,
// which the database checks again (zella_admin_refund_decide: owner only, a reason, eligibility re-checked). Amounts
// are integer cents from the database; nothing here computes money. While payments are off every list is empty.

const status = (map, s) => { const [label, tone] = map[s] ?? [String(s ?? "Unknown"), "neutral"]; return <Pill tone={tone}>{label}</Pill>; };
const notSetUp = (e) => /needs a database update|PGRST202/i.test(String(e ?? ""));
// A list must come back as a list: a missing or malformed answer is an error with a retry, never "nothing yet".
const list = (name, args) => rpc(name, args).then((v) => { if (!Array.isArray(v)) throw new Error("The list could not be loaded. Please try again."); return v; });

function Invoices({ onOpenBusiness }) {
  const [st, setSt] = useState(null);
  const r = useLoad(() => list("zella_admin_invoices", { p_business_id: null, p_status: st, p_limit: 200 }), [st]);
  return (
    <>
      <Filters><Select label="Status" value={st} onChange={setSt} options={Object.entries(INVOICE_STATUS).map(([k, [l]]) => [k, l])} /></Filters>
      {notSetUp(r.error) ? <p className="op-muted">Invoices appear here once payments are set up.</p> : <ErrorNote error={r.error} onRetry={r.reload} />}
      <DataTable loading={r.loading} error={r.error && !notSetUp(r.error)} rows={r.data ?? []} empty="No invoices yet. Stripe invoices appear here once payments are switched on."
        columns={[
          ["Business", (x) => x.business_name],
          ["Invoice", (x) => x.number ?? "Draft"],
          ["Status", (x) => status(INVOICE_STATUS, x.status)],
          ["Total", (x) => usd(x.total_minor), "op-num"],
          ["Paid", (x) => usd(x.amount_paid_minor), "op-num"],
          ["Date", (x) => when(x.created_at)],
          ["", (x) => x.hosted_invoice_url ? <a href={x.hosted_invoice_url} target="_blank" rel="noreferrer" onClick={(e) => e.stopPropagation()}>Open</a> : null],
        ]}
        onRow={onOpenBusiness ? (x) => onOpenBusiness(x.business_id) : undefined} />
    </>
  );
}

function Refunds({ me }) {
  // only the Zella Voice owner with billing.manage decides (the server checks the same); while unknown: read only
  const mayDecide = me?.role === "zella_owner" && can(me, "billing.manage");
  const [st, setSt] = useState("requested");
  const [deciding, setDeciding] = useState(null);
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState("");
  const r = useLoad(() => list("zella_admin_refunds", { p_status: st, p_limit: 200 }), [st]);
  async function decide(approve) {
    setBusy(true); setErr("");
    try { await rpc("zella_admin_refund_decide", { p_refund_id: deciding.id, p_approve: approve, p_reason: reason }); setDeciding(null); setReason(""); r.reload(); }
    catch (e) { setErr(e.message); }
    finally { setBusy(false); }
  }
  return (
    <>
      <Filters><Select label="Status" value={st} onChange={setSt} options={Object.entries(REFUND_STATUS).map(([k, [l]]) => [k, l])} /></Filters>
      {notSetUp(r.error) ? <p className="op-muted">Refund requests appear here once payments are set up.</p> : <ErrorNote error={r.error} onRetry={r.reload} />}
      <DataTable loading={r.loading} error={r.error && !notSetUp(r.error)} rows={r.data ?? []} empty="No refunds in this list."
        columns={[
          ["Business", (x) => x.business_name],
          ["Kind", (x) => REFUND_KIND[x.kind] ?? x.kind],
          ["Amount", (x) => usd(x.amount_minor), "op-num"],
          ["Status", (x) => status(REFUND_STATUS, x.status)],
          ["Asked", (x) => when(x.created_at)],
          ["", (x) => mayDecide && x.status === "requested" ? <button type="button" className="owner-secondary-button" onClick={(e) => { e.stopPropagation(); if (deciding?.id !== x.id) setReason(""); setDeciding(x); setErr(""); }}>Decide</button> : null],
        ]} />
      {mayDecide && deciding && (
        <div className="wiz-section op-gap" role="group" aria-label="Refund decision">
          <p><strong>{deciding.business_name}</strong>: {REFUND_KIND[deciding.kind] ?? deciding.kind}, {usd(deciding.amount_minor)}. Only the Zella Voice owner can decide; the rules are checked again.</p>
          <label className="owner-field wiz-field-full"><span>Reason (kept in the audit log)</span>
            <input value={reason} onChange={(e) => setReason(e.target.value)} maxLength={500} /></label>
          {err && <div className="owner-form-error" role="alert">{err}</div>}
          <div className="ic-actions">
            <button type="button" className="owner-secondary-button" onClick={() => setDeciding(null)} disabled={busy}>Cancel</button>
            <button type="button" className="owner-secondary-button" onClick={() => decide(false)} disabled={busy || reason.trim().length < 5}>Decline</button>
            <button type="button" className="owner-primary-button" onClick={() => decide(true)} disabled={busy || reason.trim().length < 5}>{busy ? "Saving..." : "Approve refund"}</button>
          </div>
        </div>
      )}
    </>
  );
}

function Disputes({ onOpenBusiness }) {
  const r = useLoad(() => list("zella_admin_disputes", { p_limit: 200 }), []);
  return (
    <>
      {notSetUp(r.error) ? <p className="op-muted">Disputes appear here once payments are set up.</p> : <ErrorNote error={r.error} onRetry={r.reload} />}
      <DataTable loading={r.loading} error={r.error && !notSetUp(r.error)} rows={r.data ?? []} empty="No disputes. A chargeback appears here with its respond by date."
        columns={[
          ["Business", (x) => x.business_name],
          ["Amount", (x) => usd(x.amount_minor), "op-num"],
          ["Status", (x) => status(DISPUTE_STATUS, x.outcome)],
          ["Reason", (x) => x.reason ?? "Not given"],
          ["Respond by", (x) => when(x.respond_by)],
          ["Opened", (x) => when(x.created_at)],
        ]}
        onRow={onOpenBusiness ? (x) => onOpenBusiness(x.business_id) : undefined} />
    </>
  );
}

const TABS = [["invoices", "Invoices"], ["refunds", "Refunds"], ["disputes", "Disputes"]];

export default function BillingRecords({ onOpenBusiness, me }) {
  const [tab, setTab] = useState("invoices");
  return (
    <Panel title="Payments" description="Invoices, refunds and disputes, recorded from verified Stripe events. Payments are switched off until the owner connects Stripe, so these lists stay empty until then.">
      <Tabs tabs={TABS} current={tab} onChange={setTab} />
      {tab === "invoices" && <Invoices onOpenBusiness={onOpenBusiness} />}
      {tab === "refunds" && <Refunds me={me} />}
      {tab === "disputes" && <Disputes onOpenBusiness={onOpenBusiness} />}
    </Panel>
  );
}
