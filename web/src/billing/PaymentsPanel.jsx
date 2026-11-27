import { useEffect, useMemo, useRef, useState } from "react";
import { useCardUpdate } from "./useCardUpdate";
import { Icon } from "../BusinessUI";
import GlassCheckout from "./GlassCheckout";
import { cardWords, formatMoney } from "./checkoutMachine";
import { invoiceAsPayment, packAnswer } from "./payState.js";
import { mountPaymentElement } from "./stripeEmbedded";
import "./payments.css";

// Paying from inside the CRM (owner decision, 27 Nov 2026: "auto charge plus Pay now"). Auto charge stays the default:
// Stripe charges the saved card on the renewal date. Here the owner sees which card that is, can update it on Stripe's
// own page, can pay an open invoice now, and can buy a pack. Every payment opens the same glass checkout; "paid" shows
// only when the server confirms it. The database decides who may see and pay (the business's active owner only).

const newKey = () => (globalThis.crypto?.randomUUID?.() ?? `${Date.now()}-${Math.random().toString(36).slice(2)}`).replace(/[^A-Za-z0-9_-]/g, "");
const day = (iso) => (iso ? new Date(iso).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" }) : "");
const RES = { minutes: "AI minutes", texts: "texts", emails: "emails" };
const STATUS = { paid: ["good", "Paid"], open: ["heads", "Open"], payment_failed: ["urgent", "Payment failed"], void: ["info", "Cancelled"], uncollectible: ["urgent", "Unpaid"] };
const cardLine = (c) => { const w = cardWords(c); return w ? `${w.brand} ending ${w.last4}` : null; };
const words = (err) => err?.words ?? err?.message ?? "Something went wrong. Please try again.";

export default function PaymentsPanel({ api, businessId, cardReturned = false }) {
  const [view, setView] = useState({ kind: "list" });
  const [data, setData] = useState({ status: "loading" });
  const update = useCardUpdate(api, businessId);
  const fetchAll = () => Promise.all([api.overview(businessId), api.invoices(businessId), api.cardSummary(businessId).catch(() => null)])
    .then(([overview, invoices, card]) => ({ status: "ok", overview, invoices: Array.isArray(invoices) ? invoices : [], card }), (error) => ({ status: "error", error }));
  function load() { setData({ status: "loading" }); fetchAll().then(setData); }
  useEffect(() => {
    let alive = true;
    fetchAll().then((d) => { if (alive) setData(d); });
    return () => { alive = false; };
  }, [businessId]); // eslint-disable-line react-hooks/exhaustive-deps

  if (view.kind === "invoice") return <InvoiceCheckout api={api} invoiceId={view.id} onBack={() => { setView({ kind: "list" }); load(); }} onUpdateCard={update.run} />;
  if (view.kind === "pack") return <PackCheckout api={api} businessId={businessId} pack={view.pack} card={data.card} onBack={() => { setView({ kind: "list" }); load(); }} onUpdateCard={update.run} />;
  if (data.status === "loading") return <p className="zpay-loading" role="status">Loading your payments…</p>;
  if (data.status === "error") {
    const notOwner = /NOT_ALLOWED/.test(data.error?.code ?? data.error?.message ?? "");
    return <div className="zob-state zob-state-box error" role="alert"><Icon name="error" /><div>
      <strong>{notOwner ? "Payments are for the business owner" : "Your payments didn't load"}</strong>
      <p>{notOwner ? "Only the owner can see and pay invoices. Ask them, or contact Zella Voice support." : words(data.error)}</p>
      {!notOwner && <button type="button" className="ba-btn sm" onClick={() => load()}>Try again</button>}</div></div>;
  }
  const { overview, invoices, card } = data;
  const sub = overview?.subscription;
  const renews = sub?.current_period_end && ["active", "past_due"].includes(sub.status) ? day(sub.current_period_end) : null;
  const which = cardLine(card);
  return (
    <div className="zpay">
      <section className="zpay-card" aria-labelledby="zpay-how">
        <h3 id="zpay-how">How you pay</h3>
        <p className="zpay-lead">{renews
          ? <>Your plan renews on <strong>{renews}</strong>. We'll charge {which ? <>your <strong>{which}</strong></> : "the card you saved with Stripe"}.</>
          : "Your plan's renewal date appears here once your first payment is confirmed."}</p>
        <p className="zob-muted">Auto charge is on: Stripe charges your saved card on each renewal date. If a payment doesn't go through, Stripe tries again a few days later, and you can pay the open invoice below at any time.</p>
        {sub?.status === "past_due" && <p className="zpay-alert" role="status"><Icon name="warning" size="sm" /> A payment didn't go through. Pay the open invoice below, or update your card: Stripe's next try uses your saved card.</p>}
        {cardReturned && <p className="zpay-note" role="status"><Icon name="task_alt" size="sm" /> You're back from Stripe. The card shown is the one Stripe has saved now.</p>}
        <div className="zpay-actions">
          <button type="button" className="ba-btn" disabled={update.busy} onClick={update.run}><Icon name="credit_card" size="sm" /> {update.busy ? "Opening Stripe…" : "Update card"}</button>
          <span className="zob-hint">Opens Stripe's secure page. Your card details never reach Zella Voice.</span>
        </div>
        {update.error && <p className="ba-error" role="alert">{update.error}</p>}
      </section>

      <section className="zpay-card" aria-labelledby="zpay-invoices">
        <h3 id="zpay-invoices">Invoices</h3>
        {invoices.length === 0 ? <p className="zob-muted">No invoices yet. Your first one appears after your first payment.</p> : (
          <ul className="zpay-list">
            {invoices.map((i) => {
              const [tone, label] = STATUS[i.status] ?? ["info", i.status];
              return (
                <li key={i.id ?? i.number} className="zpay-row">
                  <div className="zpay-row-main">
                    <strong>{i.number ?? "Invoice"}</strong>
                    <span className="zob-hint">{i.period_start ? `${day(i.period_start)} to ${day(i.period_end)}` : day(i.created_at)}</span>
                  </div>
                  <span className="zpay-amount">{formatMoney(i.status === "paid" ? i.total_minor : i.amount_due_minor ?? i.total_minor, i.currency)}</span>
                  <span className={`zob-chip zpay-chip tone-${tone}`}>{label}</span>
                  <div className="zpay-row-actions">
                    {i.payable && i.id && <button type="button" className="ba-btn primary sm" onClick={() => setView({ kind: "invoice", id: i.id })}>Pay now</button>}
                    {i.status === "paid" && i.id && <button type="button" className="ba-btn sm" onClick={() => setView({ kind: "invoice", id: i.id })}>View</button>}
                    {i.hosted_invoice_url && <a className="ba-link zpay-ext" href={i.hosted_invoice_url} target="_blank" rel="noopener noreferrer">On Stripe <Icon name="open_in_new" size="sm" /></a>}
                  </div>
                </li>
              );
            })}
          </ul>
        )}
      </section>

      {Array.isArray(overview?.packs) && overview.packs.length > 0 && (
        <section className="zpay-card" aria-labelledby="zpay-packs">
          <h3 id="zpay-packs">Add on packs</h3>
          <p className="zob-muted">Charged to your saved card. A pack lasts until the end of the month you buy it in.</p>
          <ul className="zpay-list">
            {overview.packs.map((p) => (
              <li key={p.code} className="zpay-row">
                <div className="zpay-row-main"><strong>{Number(p.quantity).toLocaleString("en-US")} {RES[p.resource] ?? p.resource}</strong></div>
                <span className="zpay-amount">{formatMoney(p.price_cents, "usd")}</span>
                <div className="zpay-row-actions"><button type="button" className="ba-btn sm" onClick={() => setView({ kind: "pack", pack: p })}>Buy</button></div>
              </li>
            ))}
          </ul>
        </section>
      )}
    </div>
  );
}

// Pay now for one invoice (the list above, or the emailed link /pay/invoice/<id>): Stripe's Payment Element on the
// invoice's own PaymentIntent, our Pay button under it. Already paid, it says so; Stripe's hosted page stays the fallback.
export function InvoiceCheckout({ api, invoiceId, onBack, onUpdateCard, backLabel = "All invoices" }) {
  const [inv, setInv] = useState({ status: "loading" });
  const [paidBefore, setPaidBefore] = useState(false);
  useEffect(() => {
    let alive = true;
    api.invoiceStatus(invoiceId).then((i) => { if (alive) { setInv({ status: "ok", invoice: i }); setPaidBefore(i?.status === "paid"); } },
      (err) => { if (alive) setInv({ status: "error", error: err }); });
    return () => { alive = false; };
  }, [api, invoiceId]);
  // one object per server answer: the checkout follows the server's state when it changes, never on a re-render
  const payment = useMemo(() => (inv.status === "ok" ? invoiceAsPayment(inv.invoice) : null), [inv]);
  const back = onBack && <button type="button" className="ba-link zob-back" onClick={onBack}><Icon name="arrow_back" size="sm" /> {backLabel}</button>;
  if (inv.status === "loading") return <>{back}<p className="zpay-loading" role="status">Loading the invoice…</p></>;
  if (inv.status === "error") return <>{back}<div className="zob-state zob-state-box error" role="alert"><Icon name="error" /><div><strong>We couldn't open this invoice</strong><p>{words(inv.error)}</p></div></div></>;
  const i = inv.invoice;
  const cannot = !i.payable && i.status !== "paid";
  const summary = {
    kicker: "Invoice", title: i.number ? `Invoice ${i.number}` : "Your invoice",
    lines: [["Period", i.period_start ? `${day(i.period_start)} to ${day(i.period_end)}` : day(i.created_at), "event"],
      ["Invoice total", formatMoney(i.total_minor, i.currency), "receipt_long"],
      ...(Number(i.amount_paid_minor) > 0 ? [["Already paid", formatMoney(i.amount_paid_minor, i.currency), "task_alt"]] : [])],
    totalLabel: i.status === "paid" ? "Due now" : "Due today", amountMinor: i.amount_due_minor, currency: i.currency,
    intro: <>You'll pay <strong>{formatMoney(i.amount_due_minor, i.currency)}</strong> for this invoice. Stripe's secure form opens right here. It's this invoice's one payment, so it can never be paid twice.</>,
    footnote: "Stripe processes this payment for Zella Voice.",
  };
  const over = {
    ...(paidBefore ? { confirmed: { label: "This invoice is paid", body: `Paid on ${day(i.paid_at)}. Nothing more is due.` } } : {}),
    off: cannot && i.payments_live !== false ? { label: "This invoice can't be paid online", body: "Nothing is due here online. If you think this is wrong, contact Zella Voice support." }
      : { label: "Paying online isn't switched on yet", body: "Nothing is charged here. Your saved card is charged automatically on the renewal date." },
  };
  return (
    <div className="zpay-checkout">
      {back}
      <GlassCheckout summary={summary} payment={payment} words={over} payLabel="Pay now" onUpdateCard={onUpdateCard}
        start={() => api.invoiceStart(invoiceId)}
        confirm={async () => { const r = await api.invoiceReturn(invoiceId); return { payment: invoiceAsPayment(r.invoice), card: r.card }; }}
        mount={(el, opts) => (api.mountPayment ? api.mountPayment(el, { ...opts, invoiceId }) : mountPaymentElement(el, opts))} />
      {i.hosted_invoice_url && i.status !== "paid" && (
        <p className="zob-muted zpay-fallback">
          Prefer Stripe's own page?{" "}
          <a className="ba-link" href={i.hosted_invoice_url} target="_blank" rel="noopener noreferrer">Pay on Stripe's invoice page</a>
        </p>
      )}
    </div>
  );
}

// Buying a pack: charged to the saved card with our Pay button (no form). If the bank wants to confirm, or the saved card
// is declined, Stripe's Payment Element opens in the same panel on the pack's own PaymentIntent. Added only when the
// server confirms it.
export function PackCheckout({ api, businessId, pack, card, onBack, onUpdateCard }) {
  const key = useRef(newKey());
  const purchase = useRef(null);
  const [payment] = useState(() => ({ status: "waiting", checkout_available: true }));
  const which = cardLine(card);
  const label = `${Number(pack.quantity).toLocaleString("en-US")} ${RES[pack.resource] ?? pack.resource}`;
  const summary = {
    kicker: "Add on pack", title: label,
    lines: [["Pack", label, "inventory_2"], ["Lasts until", "the end of this month", "event"], ["Charged to", which ?? "your saved card", "credit_card"]],
    totalLabel: "Due today", amountMinor: pack.price_cents, currency: "usd",
    intro: <>You'll pay <strong>{formatMoney(pack.price_cents, "usd")}</strong> today for {label}.</>,
    footnote: "Stripe processes this payment for Zella Voice. The price comes from your plan's pack list.",
  };
  return (
    <div className="zpay-checkout">
      {onBack && <button type="button" className="ba-link zob-back" onClick={onBack}><Icon name="arrow_back" size="sm" /> Back to payments</button>}
      <GlassCheckout summary={summary} payment={payment} payLabel={`Pay ${formatMoney(pack.price_cents, "usd")}`}
        detailsNote={which ? `Charged to your ${which}, saved with Stripe. No form needed.` : "Charged to the card you saved with Stripe. No form needed."}
        words={{ confirmed: { label: "Pack added", body: "Thank you. Your pack is confirmed and ready to use." } }} onUpdateCard={onUpdateCard}
        start={async () => {
          try { const r = await api.packBuy(businessId, pack.code, key.current); purchase.current = r.purchase_id; return { status: "processing" }; }
          catch (err) { key.current = newKey(); throw err; }
        }}
        actStart={() => api.packActStart(businessId, purchase.current)}
        confirm={async () => { const r = await api.packStatus(businessId, purchase.current); return { ...packAnswer(r.purchase), card: r.card }; }}
        mount={(el, opts) => (api.mountPayment ? api.mountPayment(el, { ...opts, purchaseId: purchase.current }) : mountPaymentElement(el, opts))} />
    </div>
  );
}
