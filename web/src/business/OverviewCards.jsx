// One business's Overview: the server's readiness ladder, the go live checklist, plan, usage, numbers and alerts
// (BIZ-11, BIZ-12 phase 1). Each card reads one part of business_detail (detail.ts) and is left out when an older
// server doesn't send it, or says "not available" when the server couldn't read it.
import { useState } from "react";
import { Pill } from "../OwnerOverview";
import { callOwnerFunction } from "../CreateBusinessWizard";
import ActionDialog from "./ActionDialog";
import { navigate } from "../router";
import { formatDate, formatDateTime } from "../ownerFormat";
import { humanize } from "../copy/labels";
import { Card, Check, Empty } from "./shared";
import { RUNG_LABELS, readinessRows } from "./readiness";

const NOT_AVAILABLE = "Not available right now. The Zella Voice team can check why.";

export function ReadinessCard({ readiness }) {
  if (!readiness) return null;
  if (!readiness.available) return <Card title="Readiness"><Empty>{NOT_AVAILABLE}</Empty></Card>;
  const { state, rows } = readinessRows(readiness.report);
  return (
    <Card title="Readiness" description={`Where this business stands, worked out by the server: ${RUNG_LABELS[state] ?? humanize(state)}.`}>
      <ul className="op-checks">
        {rows.map((r) => <Check key={r.key} ok={r.ok} title={r.title} detail={r.detail} />)}
      </ul>
      <p className="op-muted bd-hint">"Voice connection" reads the connections table, which has no rows yet, so it stays unticked until that connection is recorded.</p>
    </Card>
  );
}

export function GoLiveCard({ activation }) {
  if (!activation || activation.notAllowed) return null;
  if (!activation.available) return <Card title="Go live checklist"><Empty>{NOT_AVAILABLE}</Empty></Card>;
  const report = activation.report ?? {};
  return (
    <Card title="Go live checklist" description={report.live ? "This business is live." : report.ready ? "Everything needed to go live is in place." : "What still has to pass before this business can go live. Read only."}>
      <ul className="op-checks">
        {(report.checks ?? []).map((c) => <Check key={c.key} ok={c.ok} title={c.label} detail={c.ok ? "Done" : "Not yet"} />)}
      </ul>
      <p className="op-muted bd-hint">
        Last test call: {activation.lastTest ? `${activation.lastTest.ok ? "passed" : "failed"} ${formatDateTime(activation.lastTest.created_at)}` : "none yet"}.
      </p>
    </Card>
  );
}

const money = (cents) => (typeof cents === "number" ? `$${(cents / 100).toFixed(2)}` : null);

export function PlanCard({ plan }) {
  if (!plan) return null;
  if (!plan.available) return <Card title="Plan"><Empty>{NOT_AVAILABLE}</Empty></Card>;
  const p = plan.plan;
  return (
    <Card title="Plan" description="This business's own plan, saved in Plan & pricing.">
      {p ? (
        <dl className="op-facts">
          <div><dt>Plan</dt><dd>{humanize(p.tier)} · {humanize(p.billing_interval)} · version {p.version}</dd></div>
          {plan.pricesShown && <div><dt>Price</dt><dd>{money(p.price_cents) ?? "Not set"}</dd></div>}
          <div><dt>Included each month</dt><dd>{p.minutes} minutes · {p.texts} texts · {p.emails} emails</dd></div>
          <div><dt>Seats and numbers</dt><dd>{p.team_seats} seats · {p.phone_numbers} numbers · {p.locations} locations</dd></div>
          {!plan.pricesShown && <div><dt>Price</dt><dd className="op-muted">Shown to admins who can see billing</dd></div>}
        </dl>
      ) : <Empty>No plan saved yet. A billing admin saves one in Plan & pricing.</Empty>}
    </Card>
  );
}

export function UsageCard({ usage, action }) {
  if (!usage) return null;
  if (!usage.available) return <Card title="Usage this period"><Empty>{NOT_AVAILABLE}</Empty></Card>;
  const rows = Object.entries(usage.totals ?? {});
  return (
    <Card title="Usage this period" action={action} description={usage.period ? `${formatDate(usage.period.from)} to ${formatDate(usage.period.to)}${usage.period.trial ? " (trial)" : ""}.` : "No current billing period."}>
      {rows.length ? (
        <dl className="op-facts">
          {rows.map(([resource, t]) => (
            <div key={resource}>
              <dt>{humanize(resource)}</dt>
              <dd>{t.used} used of {t.granted} · {t.remaining} left{t.reserve ? ` · reserve ${t.reserveRemaining} of ${t.reserve}` : ""}</dd>
            </div>
          ))}
        </dl>
      ) : <Empty>No balances yet. They start with the first billing period or trial.</Empty>}
    </Card>
  );
}

export function NumbersCard({ numbers, title = "Phone numbers", canAssign, businessId }) {
  if (!numbers) return null;
  if (!numbers.available) return <Card title={title}><Empty>{NOT_AVAILABLE}</Empty></Card>;
  return (
    <Card title={title} description="Numbers Zella Voice assigned to this business."
      action={canAssign && <button type="button" className="owner-secondary-button op-small" onClick={() => navigate(`/voice/numbers?assign=${businessId}`)}>Assign a number</button>}>
      {numbers.rows.length ? (
        <ul className="op-list">
          {numbers.rows.map((n) => (
            <li key={n.id}><div><strong>{n.e164}</strong><span>{n.label || "No label"} · {humanize(n.status)}</span></div></li>
          ))}
        </ul>
      ) : <Empty>No number assigned yet.</Empty>}
    </Card>
  );
}

export function AlertsCard({ alerts }) {
  if (!alerts) return null;
  if (!alerts.available) return <Card title="Open alerts"><Empty>{NOT_AVAILABLE}</Empty></Card>;
  return (
    <Card title="Open alerts" description={alerts.count ? `${alerts.count} not resolved.` : "Nothing needs attention."}
      action={<button type="button" className="owner-secondary-button op-small" onClick={() => navigate("/operations")}>Platform operations</button>}>
      {alerts.rows.length ? (
        <ul className="op-list">
          {alerts.rows.map((a) => (
            <li key={a.id}>
              <div>
                <strong>{a.title}</strong>
                <span><Pill tone={a.severity === "urgent" ? "danger" : "warning"}>{humanize(a.severity)}</Pill> · {formatDateTime(a.last_seen_at)}{a.occurrences > 1 ? ` · ${a.occurrences} times` : ""}</span>
              </div>
            </li>
          ))}
        </ul>
      ) : <Empty>No open alerts for this business.</Empty>}
    </Card>
  );
}

// CFG-22: grant one add on pack with a reason (billing.manage). The grant runs as the admin; one key per dialog means a
// double click grants once. Not charged.
export function GrantPack({ businessId, onGranted }) {
  const [open, setOpen] = useState(false);
  const [packs, setPacks] = useState(null);
  const [packsError, setPacksError] = useState("");
  const [code, setCode] = useState("");
  const [key, setKey] = useState("");
  const [done, setDone] = useState("");
  async function start() {
    setKey(crypto.randomUUID());
    setOpen(true);
    if (!packs) await loadPacks();
  }
  // a failed or malformed answer is an error to retry, never an empty catalog
  async function loadPacks() {
    setPacksError("");
    try {
      const r = await callOwnerFunction("business_pack_catalog");
      if (!Array.isArray(r?.packs)) throw new Error("bad answer");
      setPacks(r.packs);
    } catch {
      setPacksError("The packs couldn't be loaded.");
    }
  }
  return (
    <>
      {done && <span className="op-muted" role="status">{done}</span>}
      <button type="button" className="owner-secondary-button op-small" onClick={start}>Grant a pack</button>
      {open && (
        <ActionDialog title="Grant a pack?" body="The pack's allowance is added to this period's balances. It isn't charged." button="Grant pack"
          reason={{ min: 5, max: 500 }} ready={Boolean(code)}
          onRun={(reason) => callOwnerFunction("business_pack_grant", { businessId, packCode: code, reason, idempotencyKey: key })}
          onDone={(r) => { setOpen(false); setDone(r?.result === "duplicate" ? "That pack was already granted." : "Pack granted."); onGranted?.(); }}
          onClose={() => setOpen(false)}>
          <label className="owner-field">
            <span>Pack</span>
            <select value={code} onChange={(e) => setCode(e.target.value)}>
              <option value="">{packs ? (packs.length ? "Choose a pack" : "No packs are on sale") : packsError ? "Packs not loaded" : "Loading packs…"}</option>
              {(packs ?? []).map((p) => <option key={p.code} value={p.code}>{p.quantity.toLocaleString()} {humanize(p.resource).toLowerCase()} (list price {money(p.price_cents)})</option>)}
            </select>
          </label>
          {packsError && <div className="owner-form-error" role="alert">{packsError} <button type="button" className="owner-link-button" onClick={loadPacks}>Try again</button></div>}
        </ActionDialog>
      )}
    </>
  );
}
