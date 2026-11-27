import { useEffect, useMemo, useRef, useState } from "react";
import { useCardUpdate } from "./useCardUpdate";
import { Icon, Modal } from "../BusinessUI";
import GlassCheckout from "./GlassCheckout";
import { cardWords, formatMoney } from "./checkoutMachine";
import { autopayWords, invoiceAsPayment, packAnswer } from "./payState.js";
import { mountCardFields } from "./stripeEmbedded";
import "./payments.css";

// Paying from inside the CRM (owner decision, 27 Nov 2026: "auto charge plus Pay now"). Auto charge stays the default:
// Stripe charges the saved card on the renewal date. Here the owner sees which card that is, can update it on Stripe's
// own page, can pay an open invoice now, and can buy a pack. Every payment opens the same glass checkout; "paid" shows
// only when the server confirms it. The database decides who may see and pay (the business's active owner only).

const newKey = () => (globalThis.crypto?.randomUUID?.() ?? `${Date.now()}-${Math.random().toString(36).slice(2)}`).replace(/[^A-Za-z0-9_-]/g, "");
const day = (iso) => (iso ? new Date(iso).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" }) : "");
const RES = { minutes: "AI minutes", texts: "texts", emails: "emails" };
const STATUS = { paid: ["good", "Paid"], open: ["heads", "Open"], payment_failed: ["urgent", "Payment failed"], void: ["info", "Cancelled"], uncollectible: ["urgent", "Unpaid"] };
const cardLine = (c) => { const w = cardWords(c); return w ? `${w.brand} •••• ${w.last4}` : null; };
const plusDays = (iso, n) => (iso ? new Date(new Date(iso).getTime() + n * 86400000).toISOString() : null);
const words = (err) => err?.words ?? err?.message ?? "Something went wrong. Please try again.";

export default function PaymentsPanel({ api, businessId, cardReturned = false }) {
  const [view, setView] = useState({ kind: "list" });
  const [data, setData] = useState({ status: "loading" });
  const update = useCardUpdate(api, businessId);
  const fetchAll = () => Promise.all([api.overview(businessId), api.invoices(businessId), api.cardSummary(businessId).catch(() => null),
    api.autopayStatus ? api.autopayStatus(businessId).catch(() => null) : null])
    .then(([overview, invoices, card, autopay]) => ({ status: "ok", overview, invoices: Array.isArray(invoices) ? invoices : [], card, autopay }), (error) => ({ status: "error", error }));
  // Auto pay (owner, 27 Nov 2026): a switch, confirmed in a short dialog both ways; Stripe's event changes it, so the
  // page looks again until the change is through
  const [ask, setAsk] = useState(null);   // { on } while the dialog is open
  const [apBusy, setApBusy] = useState(false);
  const [apError, setApError] = useState("");
  const apKey = useRef(null);
  async function setAutopay(on) {
    if (apBusy) return;
    setApBusy(true); setApError("");
    apKey.current = apKey.current ?? newKey();   // a double submit sends the same key
    try {
      const a = await api.autopaySet(businessId, on, apKey.current);
      apKey.current = null; setAsk(null);
      setData((d) => (d.status === "ok" ? { ...d, autopay: a ?? d.autopay } : d));
      for (let i = 0; i < 6 && a?.pending; i++) {
        await new Promise((r) => setTimeout(r, 600 * (i + 1)));
        const now = await api.autopayStatus(businessId).catch(() => null);
        if (now) setData((d) => (d.status === "ok" ? { ...d, autopay: now } : d));
        if (now && !now.pending) break;
      }
    } catch (err) {
      apKey.current = null;
      setApError(words(err));
    } finally { setApBusy(false); }
  }
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
  const { overview, invoices, card, autopay } = data;
  const sub = overview?.subscription;
  const active = sub?.current_period_end && ["active", "past_due"].includes(sub.status);
  const renews = active ? day(sub.current_period_end) : null;
  const which = cardLine(card);
  const apOn = autopay?.on !== false;
  const due = active ? day(plusDays(sub.current_period_end, Number(autopay?.days_until_due ?? 3))) : null;
  const canSwitch = Boolean(autopay && autopay.subscribed !== false && autopay.payments_live !== false && api.autopaySet);
  const needCard = ask?.on && (autopay?.has_card === false || !card);
  return (
    <div className="zpay">
      <section className="zpay-card" aria-labelledby="zpay-how">
        <h3 id="zpay-how">How you pay</h3>
        <p className="zpay-lead">{!renews ? "Your plan's renewal date appears here once your first payment is confirmed."
          : apOn ? <>Your plan renews on <strong>{renews}</strong>. We'll charge {which ? <>your <strong>{which}</strong></> : "the card you saved with Stripe"}.</>
          : <>Your next invoice is due <strong>{due}</strong>. Pay it with <strong>Pay now</strong> below.</>}</p>
        <div className="zpay-autopay">
          <div className="zpay-autopay-text">
            <strong id="zpay-autopay-label">Auto pay</strong>
            <span className="zob-hint">{apOn ? "On: Stripe charges your saved card on each renewal date. If a payment doesn't go through, Stripe tries again a few days later, and you can pay the open invoice below at any time."
              : `Off: ${autopayWords(autopay?.email_live === true).offText}`}</span>
          </div>
          {canSwitch && (
            <button type="button" role="switch" aria-checked={autopay?.desired ?? apOn} aria-labelledby="zpay-autopay-label" className={`ba-switch${(autopay?.desired ?? apOn) ? " on" : ""}`}
              disabled={apBusy || autopay?.pending} onClick={() => { setApError(""); setAsk({ on: !(autopay?.desired ?? apOn) }); }}><span /></button>
          )}
        </div>
        {autopay?.pending && <p className="zpay-note" role="status"><Icon name="hourglass_top" size="sm" /> {autopay.desired ? "Turning Auto pay on" : "Turning Auto pay off"}: waiting for Stripe to confirm the change.</p>}
        {apError && !ask && <p className="ba-error" role="alert">{apError}</p>}
        {sub?.status === "past_due" && <p className="zpay-alert" role="status"><Icon name="warning" size="sm" /> A payment didn't go through. Pay the open invoice below, or update your card: Stripe's next try uses your saved card.</p>}
        {cardReturned && <p className="zpay-note" role="status"><Icon name="task_alt" size="sm" /> You're back from Stripe. The card shown is the one Stripe has saved now.</p>}
        <div className="zpay-actions">
          <button type="button" className="ba-btn" disabled={update.busy} onClick={update.run}><Icon name="credit_card" size="sm" /> {update.busy ? "Opening Stripe…" : "Update card"}</button>
          <span className="zob-hint">Opens Stripe's secure page. Your card details never reach Zella Voice.</span>
        </div>
        {update.error && <p className="ba-error" role="alert">{update.error}</p>}
      </section>

      {ask && (
        <Modal title={ask.on ? "Turn Auto pay on?" : "Turn Auto pay off?"} busy={apBusy} onClose={() => setAsk(null)}
          footer={<>
            <button type="button" className="ba-btn" disabled={apBusy} onClick={() => setAsk(null)}>Cancel</button>
            {needCard
              ? <button type="button" className="ba-btn primary" disabled={update.busy} onClick={() => { setAsk(null); update.run(); }}><Icon name="credit_card" size="sm" /> Update card</button>
              : <button type="button" className="ba-btn primary" disabled={apBusy} onClick={() => setAutopay(ask.on)}>{apBusy ? "Saving…" : ask.on ? "Turn on" : "Turn off"}</button>}
          </>}>
          <div className="zpay-dialog">
            {ask.on
              ? <p>{needCard ? "Auto pay needs a working saved card. Update your card on Stripe's secure page first, then turn Auto pay on." : `Stripe will charge ${which ? `your ${which}` : "your saved card"} on each renewal date.`}</p>
              : <p>Stripe will stop charging your card automatically. {autopayWords(autopay?.email_live === true).offText} An unpaid invoice pauses your receptionist 5 days after it's due.</p>}
            {apError && <p className="ba-error" role="alert">{apError}</p>}
          </div>
        </Modal>
      )}

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

// Pay now for one invoice (the list above, or the emailed link /pay/invoice/<id>): Stripe's card fields and billing address on the
// invoice's own PaymentIntent, our Pay button under it. Already paid, it says so, with the PDF. Stripe's hosted invoice
// page is offered only as an error fallback, when Stripe's form can't load here (owner, 27 Nov 2026).
const safeUrl = (u) => (typeof u === "string" && /^https:\/\/[^\s"'<>]+$/.test(u) ? u : null);
export function InvoiceCheckout({ api, invoiceId, onBack, onUpdateCard, backLabel = "All invoices" }) {
  const [inv, setInv] = useState({ status: "loading" });
  const [paidBefore, setPaidBefore] = useState(false);
  // Auto pay (owner, 27 Nov 2026): on by default; starts from what Stripe has; a change is sent once the payment is confirmed
  const [ap, setAp] = useState(null);
  const [apOn, setApOn] = useState(true);
  const [apNote, setApNote] = useState("");
  const apSent = useRef(false);
  const businessOf = inv.status === "ok" ? inv.invoice?.business_id : null;
  useEffect(() => {
    if (!businessOf || !api.autopayStatus) return undefined;
    let alive = true;
    api.autopayStatus(businessOf).then((a) => { if (alive && a) { setAp(a); setApOn(a.on !== false); } }, () => {});
    return () => { alive = false; };
  }, [api, businessOf]);
  function onPayment(p) {
    if (p?.status !== "confirmed" || apSent.current || !ap || !api.autopaySet || apOn === (ap.on !== false)) return;
    apSent.current = true;
    api.autopaySet(businessOf, apOn, newKey()).then(
      () => setApNote(apOn ? "Auto pay is on: Stripe charges your saved card on each renewal date." : `Auto pay is off. ${autopayWords(ap.email_live === true).offText}`),
      (err) => setApNote(`Auto pay wasn't changed. ${words(err)}`));
  }
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
        fallbackUrl={i.status !== "paid" ? safeUrl(i.hosted_invoice_url) : null} onPayment={onPayment}
        autopay={ap && !paidBefore ? { on: apOn, onChange: setApOn, ...autopayWords(ap.email_live === true, "your saved card") } : null}
        start={() => api.invoiceStart(invoiceId)}
        confirm={async () => { const r = await api.invoiceReturn(invoiceId); return { payment: invoiceAsPayment(r.invoice), card: r.card }; }}
        kind="intent" saveNote="Stripe uses this card for this invoice only. Your saved card stays as it is."
        mount={(slots, opts) => (api.mountPayment ? api.mountPayment(slots, { ...opts, invoiceId }) : mountCardFields(slots, opts))} />
      {apNote && <p className="zob-muted zpay-apnote" role="status">{apNote}</p>}
      {safeUrl(i.invoice_pdf) && (
        <div className="zpay-actions zpay-pdf">
          <a className="ba-btn" href={safeUrl(i.invoice_pdf)} target="_blank" rel="noopener noreferrer"><Icon name="download" size="sm" /> Download PDF</a>
        </div>
      )}
    </div>
  );
}

// Buying a pack: charged to the saved card with our Pay button (no form). If the bank wants to confirm, or the saved card
// is declined, Stripe's card fields open in the same panel on the pack's own PaymentIntent. Added only when the
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
        kind="intent" saveNote="Stripe uses this card for this pack only."
        mount={(slots, opts) => (api.mountPayment ? api.mountPayment(slots, { ...opts, purchaseId: purchase.current }) : mountCardFields(slots, opts))} />
    </div>
  );
}
