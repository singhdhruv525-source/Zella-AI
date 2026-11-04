import { useMemo, useState } from "react";
import { supabase } from "./supabase";
import { Field, Icon, Modal, Pill, personName } from "./BusinessUI";
import { formatDay, timeAgo } from "./businessTime";
import { Empty, PageHead, explain, orThrow, useLoad } from "./BusinessShared";
import { PersonPicker } from "./BusinessWork";

// Money the team records: estimates, invoices, deposits, no-show fees and gift cards, and payments against them
// (zella_money.sql). Zella never takes card details and never charges anyone; payments here are what the team took
// elsewhere (cash, a card terminal, a bank transfer), or what a payment provider confirmed. Staff add charges, managers
// record payments, owners and admins refund. The database checks every one of these again.

const KINDS = [["invoice", "Invoice"], ["estimate", "Estimate"], ["deposit", "Deposit"], ["no_show_fee", "No-show fee"], ["gift_card", "Gift card"]];
const KIND_LABEL = Object.fromEntries(KINDS);
const STATUS = {
  proposed: ["Proposed", "info"], accepted: ["Accepted", "success"], declined: ["Declined", ""], open: ["Unpaid", "warning"],
  partially_paid: ["Part paid", "warning"], paid: ["Paid", "success"], refunded: ["Refunded", ""], void: ["Void", ""],
};
const METHODS = [["cash", "Cash"], ["card_terminal", "Card terminal"], ["bank_transfer", "Bank transfer"], ["check", "Check"], ["other", "Other"]];

const digits = (currency) => (["JPY", "KRW", "VND", "CLP", "ISK"].includes(currency) ? 0 : ["BHD", "KWD", "OMR", "JOD", "TND"].includes(currency) ? 3 : 2);
export const showMoney = (minor, currency) => {
  const d = digits(currency);
  try { return (Number(minor) / 10 ** d).toLocaleString(undefined, { style: "currency", currency, minimumFractionDigits: d, maximumFractionDigits: d }); }
  catch { return `${(Number(minor) / 10 ** d).toFixed(d)} ${currency}`; }
};
// "12.50" -> 1250, exactly (no floating point); null when it isn't a plain amount with at most the currency's decimals.
export const toMinor = (text, currency) => {
  const d = digits(currency);
  const m = String(text ?? "").trim().replace(/,/g, "").match(d ? new RegExp(`^(\\d{1,10})(?:\\.(\\d{1,${d}}))?$`) : /^(\d{1,12})$/);
  if (!m) return null;
  const minor = Number(m[1]) * 10 ** d + Number((m[2] ?? "").padEnd(d, "0") || 0);
  return minor > 0 ? minor : null;
};
const newKey = () => (crypto.randomUUID ? crypto.randomUUID() : `${Date.now()}-${Math.random()}`);

function NewCharge({ workspace, currency, onClose, onSaved }) {
  const [kind, setKind] = useState("invoice");
  const [amount, setAmount] = useState("");
  const [description, setDescription] = useState("");
  const [person, setPerson] = useState(null);
  const [due, setDue] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [key] = useState(newKey); // one key per form, so a double click can't make two

  async function save(event) {
    event.preventDefault();
    const minor = toMinor(amount, currency);
    if (!minor) return setError(`Enter an amount like ${digits(currency) ? "120.50" : "1200"}.`);
    setBusy(true); setError("");
    const { error: failure } = await supabase.rpc("zella_create_charge", {
      p_business_id: workspace.id, p_kind: kind, p_amount_minor: minor, p_description: description || null,
      p_customer_id: person?.id ?? null, p_due_on: due || null, p_idempotency_key: key,
    });
    setBusy(false);
    if (failure) return setError(explain(failure));
    onSaved(`${KIND_LABEL[kind]} added.`);
  }

  return (
    <Modal title="Add to Money" description="A record for your team. Zella doesn't send it or charge anyone." onClose={onClose} busy={busy}
      footer={<><button type="button" className="ba-btn" onClick={onClose} disabled={busy}>Cancel</button>
        <button type="submit" form="ba-money-form" className="ba-btn primary" disabled={busy}>{busy ? "Saving…" : "Add"}</button></>}>
      <form id="ba-money-form" className="ba-modal-body" onSubmit={save}>
        {error && <p className="ba-error" role="alert">{error}</p>}
        <div className="ba-form-grid">
          <Field label="Type">
            <select value={kind} onChange={(e) => setKind(e.target.value)}>{KINDS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select>
          </Field>
          <Field label={`Amount (${currency})`}><input inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} required /></Field>
          <Field label="What it's for" full><input value={description} onChange={(e) => setDescription(e.target.value)} maxLength={500} /></Field>
          {kind !== "estimate" && kind !== "gift_card" && <Field label="Due"><input type="date" value={due} onChange={(e) => setDue(e.target.value)} /></Field>}
        </div>
        <PersonPicker businessId={workspace.id} label={workspace.terminology?.customer ?? "Customer"} value={person} onChange={setPerson} hint="Optional." />
        {kind === "no_show_fee" && <p className="ba-muted">This records a fee. Zella doesn't charge it; collect it the way you normally take payment.</p>}
      </form>
    </Modal>
  );
}

function ChargeDetail({ workspace, charge, onClose, onChanged }) {
  const role = workspace.role;
  const canPay = ["owner", "admin", "manager"].includes(role);
  const canRefund = ["owner", "admin"].includes(role);
  const [kind, setKind] = useState("payment");
  const [amount, setAmount] = useState("");
  const [method, setMethod] = useState("cash");
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [key, setKey] = useState(newKey);
  const info = useLoad(async () => {
    const [bal, pays] = await Promise.all([
      supabase.rpc("zella_charge_balance", { p_charge_id: charge.id }),
      supabase.from("customer_charge_payments").select("*").eq("charge_id", charge.id).order("created_at"),
    ]);
    if (bal.error) throw bal.error;
    return { balance: bal.data, payments: orThrow(pays) };
  }, [charge.id, charge.status]);
  const cur = charge.currency;
  const b = info.data?.balance;
  const payable = !["estimate"].includes(charge.kind) && charge.status !== "void";
  const kinds = [["payment", charge.kind === "gift_card" ? "Sold" : "Payment"], ...(charge.kind === "gift_card" ? [["redemption", "Used"]] : []), ...(canRefund ? [["refund", "Refund"]] : [])];

  async function act(work, message) {
    setBusy(true); setError("");
    const { error: failure } = await work();
    setBusy(false);
    if (failure) {
      const text = failure.message ?? "";
      return setError(/MORE_THAN_OWED/.test(text) ? "That's more than is left to pay." : /MORE_THAN_PAID/.test(text) ? "That's more than was paid."
        : /HAS_PAYMENTS/.test(text) ? "This has payments, so it can't be voided. Refund instead." : /NOT_PAID/.test(text) ? "Record the gift card as sold first."
          : /ALREADY_PAID/.test(text) ? "This gift card is already sold." : explain(failure));
    }
    setAmount(""); setNote(""); setKey(newKey());
    onChanged(message);
  }
  function record(event) {
    event.preventDefault();
    const minor = toMinor(amount, cur);
    if (!minor) return setError("Enter an amount.");
    act(() => supabase.rpc("zella_record_charge_payment", { p_charge_id: charge.id, p_kind: kind, p_amount_minor: minor,
      p_method: kind === "redemption" ? "gift_card" : method, p_note: note || null, p_idempotency_key: key }),
    kind === "refund" ? "Refund recorded." : kind === "redemption" ? "Gift card use recorded." : "Payment recorded.");
  }

  const [label, tone] = STATUS[charge.status] ?? [charge.status, ""];
  return (
    <Modal wide title={`${KIND_LABEL[charge.kind]} ${charge.number ?? ""}`.trim()} description={charge.description ?? undefined} onClose={onClose} busy={busy}
      footer={<>
        {canPay && charge.kind === "estimate" && charge.status === "proposed" && <>
          <button type="button" className="ba-btn" disabled={busy} onClick={() => act(() => supabase.rpc("zella_set_charge_status", { p_charge_id: charge.id, p_status: "declined" }), "Marked declined.")}>Declined</button>
          <button type="button" className="ba-btn" disabled={busy} onClick={() => act(() => supabase.rpc("zella_set_charge_status", { p_charge_id: charge.id, p_status: "accepted" }), "Marked accepted.")}>Accepted</button>
        </>}
        {canPay && charge.status !== "void" && !(info.data?.payments ?? []).length && <button type="button" className="ba-btn ghost danger" disabled={busy}
          onClick={() => window.confirm("Void this? It stays in the list as void.") && act(() => supabase.rpc("zella_set_charge_status", { p_charge_id: charge.id, p_status: "void" }), "Voided.")}>Void</button>}
        <button type="button" className="ba-btn" onClick={onClose}>Close</button>
      </>}>
      <div className="ba-modal-body">
        {error && <p className="ba-error" role="alert">{error}</p>}
        <dl className="ba-facts">
          <div><dt>Status</dt><dd><Pill tone={tone}>{label}</Pill></dd></div>
          <div><dt>Amount</dt><dd>{showMoney(charge.amount_minor, cur)}</dd></div>
          {b && payable && <div><dt>{charge.kind === "gift_card" ? "Paid" : "Left to pay"}</dt><dd>{charge.kind === "gift_card" ? showMoney(b.paid_minor, cur) : showMoney(Math.max(0, b.balance_minor), cur)}</dd></div>}
          {b && b.provider_minor > 0 && <div><dt>Confirmed by payment provider</dt><dd>{showMoney(b.provider_minor, cur)}</dd></div>}
          {b && b.manual_minor > 0 && <div><dt>Recorded by your team</dt><dd>{showMoney(b.manual_minor, cur)}</dd></div>}
          {charge.due_on && <div><dt>Due</dt><dd>{formatDay(charge.due_on, workspace.timezone)}</dd></div>}
        </dl>
        {charge.kind === "estimate" && <p className="ba-muted">An estimate is a proposal, not money owed. When the work goes ahead, add an invoice.</p>}
        <h3 className="ba-h3">Payments</h3>
        {(info.data?.payments ?? []).length === 0 ? <p className="ba-muted">None recorded.</p> : (
          <ul className="ba-history">
            {info.data.payments.map((p) => (
              <li key={p.id}><strong>{{ payment: "Payment", refund: "Refund", redemption: "Gift card used" }[p.kind]} · {showMoney(p.amount_minor, cur)}</strong>
                {` · ${p.source === "provider" ? "confirmed by payment provider" : METHODS.find(([v]) => v === p.method)?.[1] ?? p.method}`}{p.note ? ` · ${p.note}` : ""}
                <small>{timeAgo(p.created_at)}</small></li>
            ))}
          </ul>
        )}
        {payable && canPay && (
          <form className="ba-form-grid" onSubmit={record} style={{ marginTop: 12 }}>
            <Field label="Record"><select value={kind} onChange={(e) => setKind(e.target.value)}>{kinds.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></Field>
            <Field label={`Amount (${cur})`}><input inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} /></Field>
            {kind !== "redemption" && <Field label="How"><select value={method} onChange={(e) => setMethod(e.target.value)}>{METHODS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></Field>}
            <Field label="Note"><input value={note} onChange={(e) => setNote(e.target.value)} maxLength={500} /></Field>
            <div><button type="submit" className="ba-btn primary" disabled={busy}>Record</button></div>
          </form>
        )}
        {payable && !canPay && <p className="ba-muted">Managers and above record payments.</p>}
        <p className="ba-muted">Never type card numbers here. Zella records payments; it doesn't take them.</p>
      </div>
    </Modal>
  );
}

export function MoneyPage({ workspace, refreshKey, onNotice, onOpenPerson }) {
  const tz = workspace.timezone;
  const [filter, setFilter] = useState("open");
  const [modal, setModal] = useState(null);
  const [version, setVersion] = useState(0);
  const currency = useLoad(async () => {
    const r = await supabase.rpc("zella_business_currency", { p_business_id: workspace.id });
    return r.error ? "USD" : r.data || "USD";
  }, [workspace.id]);
  const { data, error, loading } = useLoad(async () => orThrow(await supabase.from("customer_charges")
    .select("*, customers(id, first_name, last_name, company_name)").eq("business_id", workspace.id).order("created_at", { ascending: false }).limit(500)),
  [workspace.id, refreshKey, version]);
  const rows = useMemo(() => (data ?? []).filter((c) => (filter === "all" ? true : filter === "open" ? ["open", "partially_paid", "proposed", "accepted"].includes(c.status) : c.kind === filter)), [data, filter]);
  const owed = useMemo(() => {
    const out = {};
    for (const c of data ?? []) if (["open", "partially_paid"].includes(c.status) && c.kind !== "gift_card") out[c.currency] = (out[c.currency] ?? 0) + c.amount_minor;
    return out;
  }, [data]);
  const changed = (message) => { onNotice(message); setVersion((v) => v + 1); };
  const current = modal?.charge ? (data ?? []).find((c) => c.id === modal.charge.id) ?? modal.charge : null;

  return (
    <>
      <PageHead crumb="CRM / Money" title="Money" sub="Estimates, invoices, deposits, fees and gift cards your team records. Zella never takes card details or charges anyone.">
        {workspace.role !== "viewer" && <button type="button" className="ba-btn primary" onClick={() => setModal({ new: true })}><Icon name="add" size="sm" />Add</button>}
      </PageHead>
      <div className="ba-toolbar">
        <label className="ba-inline">Show <select value={filter} onChange={(e) => setFilter(e.target.value)}>
          <option value="open">Open</option><option value="all">All</option>{KINDS.map(([v, l]) => <option key={v} value={v}>{l}s</option>)}
        </select></label>
        {Object.keys(owed).length > 0 && <span className="ba-muted">Unpaid invoices, deposits and fees (full amounts): {Object.entries(owed).map(([c, m]) => showMoney(m, c)).join(" · ")}</span>}
      </div>
      {error && <div className="ba-banner error">{explain(error)}</div>}
      {rows.length === 0 ? <Empty icon="payments" title={loading ? "Loading…" : "Nothing here yet"}>{!loading && "Add an estimate, invoice, deposit or gift card when you need to keep track of one."}</Empty> : (
        <div className="ba-table-wrap" tabIndex={0}>
          <table className="ba-table">
            <thead><tr><th>Number</th><th>Type</th><th>{workspace.terminology?.customer ?? "Customer"}</th><th>Amount</th><th>Status</th><th>Due</th><th>Added</th></tr></thead>
            <tbody>
              {rows.map((c) => {
                const [label, tone] = STATUS[c.status] ?? [c.status, ""];
                return (
                  <tr key={c.id} onClick={() => setModal({ charge: c })} tabIndex={0} onKeyDown={(e) => e.key === "Enter" && setModal({ charge: c })}>
                    <td><strong>{c.number ?? "—"}</strong>{c.description ? <small className="td-sub">{c.description}</small> : null}</td>
                    <td>{KIND_LABEL[c.kind]}</td>
                    <td>{c.customers ? <button type="button" className="ba-namebtn" onClick={(e) => { e.stopPropagation(); onOpenPerson?.(c.customers.id); }}>{personName(c.customers)}</button> : "—"}</td>
                    <td>{showMoney(c.amount_minor, c.currency)}</td>
                    <td><Pill tone={tone}>{label}</Pill></td>
                    <td>{c.due_on ? formatDay(c.due_on, tz) : "—"}</td>
                    <td>{timeAgo(c.created_at)}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
      {modal?.new && <NewCharge workspace={workspace} currency={currency.data ?? "USD"} onClose={() => setModal(null)} onSaved={(m) => { setModal(null); changed(m); }} />}
      {current && <ChargeDetail workspace={workspace} charge={current} onClose={() => setModal(null)} onChanged={changed} />}
    </>
  );
}
