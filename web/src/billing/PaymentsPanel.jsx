import { useEffect, useMemo, useRef, useState } from "react";
import { useCardUpdate } from "./useCardUpdate";
import { Icon, Modal } from "../BusinessUI";
import GlassCheckout from "./GlassCheckout";
import { cardWords, formatMoney, keyIsSpent } from "./checkoutMachine";
import { autopayWords, invoiceAsPayment, nextPaymentLine, packAnswer } from "./payState.js";
import { mountCardFields } from "./stripeEmbedded";
import { addonKeys, addonRows, addonStep, addonsTotal, consentHash, invoiceConsent, offerFrom, packConsent, toggle } from "./addons.js";
import { AddonProgress } from "./ReceiptExtras";
import { fromServer } from "./checkoutMachine";
import "./payments.css";

// Paying from inside the CRM (owner decision, 27 Nov 2026: "auto charge plus Pay now"). Auto charge stays the default:
// Stripe charges the saved card on the renewal date. Here the owner sees which card that is, can update it on Stripe's
// own page, can pay an open invoice now, and can buy a pack. Every payment opens the same glass checkout; "paid" shows
// only when the server confirms it. The database decides who may see and pay (the business's active owner only).

const newKey = () => (globalThis.crypto?.randomUUID?.() ?? `${Date.now()}-${Math.random().toString(36).slice(2)}`).replace(/[^A-Za-z0-9_-]/g, "");
const shortDay = (iso) => (iso ? new Date(iso).toLocaleDateString("en-US", { month: "short", day: "numeric" }) : "");
const planName = (t) => String(t).charAt(0).toUpperCase() + String(t).slice(1);
const day = (iso) => (iso ? new Date(iso).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" }) : "");
const RES = { minutes: "AI minutes", texts: "texts", emails: "emails" };
const STATUS = { paid: ["good", "Paid"], open: ["heads", "Open"], payment_failed: ["urgent", "Payment failed"], void: ["info", "Cancelled"], uncollectible: ["urgent", "Unpaid"] };
const cardLine = (c) => { const w = cardWords(c); return w ? `${w.brand} •••• ${w.last4}` : null; };
const plusDays = (iso, n) => (iso ? new Date(new Date(iso).getTime() + n * 86400000).toISOString() : null);
const words = (err) => err?.words ?? err?.message ?? "Something went wrong. Please try again.";

export default function PaymentsPanel({ api, businessId, cardReturned = false, onOpenInvoice, onOpenPack }) {
  const [view, setView] = useState({ kind: "list" });
  const [data, setData] = useState({ status: "loading" });
  const update = useCardUpdate(api, businessId);
  useEffect(() => {   // back from Stripe's card page: the note shows once, and the flag leaves the address bar
    if (!cardReturned) return;
    const u = new URL(window.location.href); u.searchParams.delete("card");
    window.history.replaceState(window.history.state, "", u.pathname + u.search + u.hash);
  }, [cardReturned]);
  const fetchAll = () => Promise.all([api.overview(businessId), api.invoices(businessId), api.cardSummary(businessId).catch(() => null),
    api.autopayStatus ? api.autopayStatus(businessId).catch(() => null) : null])
    .then(([overview, invoices, card, autopay]) => ({ status: "ok", overview, invoices: Array.isArray(invoices) ? invoices : [], card, autopay }), (error) => ({ status: "error", error }));
  // Auto pay (owner, 27 Nov 2026): a switch, confirmed in a short dialog both ways; Stripe's event changes it, so the
  // page looks again until the change is through
  const [ask, setAsk] = useState(null);   // { on } while the dialog is open
  const [apBusy, setApBusy] = useState(false);
  const [apError, setApError] = useState("");
  const apKey = useRef(null);
  const [apStale, setApStale] = useState(false);   // still waiting for Stripe after the quick checks: the owner can look again
  async function refreshAutopay() {
    if (!api.autopayStatus) return;
    setApBusy(true);
    try { const now = await api.autopayStatus(businessId); setData((d) => (d.status === "ok" ? { ...d, autopay: now } : d)); setApStale(Boolean(now?.pending)); }
    catch (err) { setApError(words(err)); }
    finally { setApBusy(false); }
  }
  async function setAutopay(on) {
    if (apBusy) return;
    setApBusy(true); setApError("");
    apKey.current = apKey.current ?? newKey();   // a double submit sends the same key
    try {
      const a = await api.autopaySet(businessId, on, apKey.current);
      apKey.current = null; setAsk(null);
      setData((d) => (d.status === "ok" ? { ...d, autopay: a ?? d.autopay } : d));
      let last = a;
      for (let i = 0; i < 6 && last?.pending; i++) {
        await new Promise((r) => setTimeout(r, 600 * (i + 1)));
        const now = await api.autopayStatus(businessId).catch(() => null);
        if (now) { last = now; setData((d) => (d.status === "ok" ? { ...d, autopay: now } : d)); }
      }
      setApStale(Boolean(last?.pending));   // the quick checks ran out: offer Check again (review)
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
  // Auto pay as the server says it (review): a lookup that failed or hasn't answered is "not known", never "on"; no
  // promise of an automatic charge is shown until it has loaded
  const apKnown = typeof autopay?.on === "boolean";
  const apOn = apKnown && autopay.on;
  const due = active ? day(plusDays(sub.current_period_end, Number(autopay?.days_until_due ?? 3))) : null;
  const canSwitch = Boolean(apKnown && autopay.subscribed !== false && autopay.payments_live !== false && api.autopaySet);
  const needCard = ask?.on && (autopay?.has_card === false || !card);
  // a payment opens its own CRM page when the CRM gives the way (owner, 27 Nov 2026); else it opens here
  const openInvoice = (id) => (onOpenInvoice ? onOpenInvoice(id) : setView({ kind: "invoice", id }));
  const openPack = (p) => (onOpenPack ? onOpenPack(p.code) : setView({ kind: "pack", pack: p }));
  // what's next when nothing is open: information only. Paying before Stripe makes the renewal invoice isn't offered
  // (owner decision, 27 Nov 2026)
  const openInvoices = invoices.filter((i) => i.payable);
  const nextAmount = overview?.plan?.price_cents;
  const nextLine = active && !openInvoices.length && Number.isFinite(Number(nextAmount))
    // Auto pay not known (the lookup failed): the amount and date only, never "off" or a deadline (review round 3)
    ? nextPaymentLine({ amount: formatMoney(nextAmount, overview?.plan?.currency ?? "usd"), date: day(sub.current_period_end), apKnown, apOn, due })
    : null;
  return (
    <div className="zpay">
      <section className="zpay-card" aria-labelledby="zpay-how">
        <h3 id="zpay-how">How you pay</h3>
        <p className="zpay-lead">{!renews ? "Your plan's renewal date appears here once your first payment is confirmed."
          : !apKnown ? <>Your plan renews on <strong>{renews}</strong>.</>
          : apOn ? <>Your plan renews on <strong>{renews}</strong>. We'll charge {which ? <>your <strong>{which}</strong></> : "the card you saved with Stripe"}.</>
          : <>Your next invoice is due <strong>{due}</strong>. Pay it with <strong>Pay now</strong> below.</>}</p>
        <div className="zpay-autopay">
          <div className="zpay-autopay-text">
            <strong id="zpay-autopay-label">Auto pay</strong>
            <span className="zob-hint">{!apKnown ? "We couldn't load your Auto pay setting just now."
              : apOn ? "On. We'll charge your saved card on each renewal date."
              : `Off. ${autopayWords(autopay?.email_live === true).offText}`}</span>
          </div>
          {!apKnown && <button type="button" className="ba-btn sm" disabled={apBusy} onClick={refreshAutopay}>Check again</button>}
          {canSwitch && (
            <button type="button" role="switch" aria-checked={autopay?.desired ?? apOn} aria-labelledby="zpay-autopay-label" className={`ba-switch${(autopay?.desired ?? apOn) ? " on" : ""}`}
              disabled={apBusy || autopay?.pending} onClick={() => { setApError(""); setAsk({ on: !(autopay?.desired ?? apOn) }); }}><span /></button>
          )}
        </div>
        {autopay?.pending && <p className="zpay-note" role="status"><Icon name="hourglass_top" size="sm" /> {autopay.desired ? "Turning Auto pay on…" : "Turning Auto pay off…"}
          {apStale && <> <button type="button" className="ba-link" disabled={apBusy} onClick={refreshAutopay}>Check again</button></>}</p>}
        {apError && !ask && <p className="ba-error" role="alert">{apError}</p>}
        {nextLine && <p className="zpay-next" role="note"><Icon name="event" size="sm" /> {nextLine}</p>}
        {sub?.status === "past_due" && <p className="zpay-alert" role="status"><Icon name="warning" size="sm" /> A payment didn't go through. Pay it below, or update your card.</p>}
        {cardReturned && <p className="zpay-note" role="status"><Icon name="task_alt" size="sm" /> Your card is updated.</p>}
        <div className="zpay-actions">
          <button type="button" className="ba-btn" disabled={update.busy} onClick={update.run}><Icon name="credit_card" size="sm" /> {update.busy ? "Opening Stripe…" : "Update card"}</button>
          <span className="zob-hint">Opens Stripe's secure page.</span>
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
              ? <p>{needCard ? "Auto pay needs a saved card that works. Update your card first." : `We'll charge ${which ? `your ${which}` : "your saved card"} on each renewal date.`}</p>
              : <><p>{autopayWords(autopay?.email_live === true).offText}</p><p>An unpaid bill pauses your AI receptionist 5 days after it's due.</p></>}
            {apError && <p className="ba-error" role="alert">{apError}</p>}
          </div>
        </Modal>
      )}

      <section className="zpay-card" aria-labelledby="zpay-invoices">
        <h3 id="zpay-invoices">Invoices</h3>
        {invoices.length === 0 ? <p className="zob-muted">No invoices yet.</p> : (
          <ul className="zpay-list">
            {invoices.map((i) => {
              const [tone, label] = STATUS[i.status] ?? ["info", i.status];
              return (
                <li key={i.id ?? i.number} className="zpay-row" data-invoice={i.number ?? undefined}>
                  {/* the invoice number stays in the PDF (owner, 27 Nov 2026): the row says what the payment covers */}
                  <div className="zpay-row-main">
                    <strong>{i.period_start ? `${day(i.period_start)} to ${day(i.period_end)}` : day(i.created_at)}</strong>
                    <span className="zob-hint">Your plan</span>
                  </div>
                  <span className="zpay-amount">{formatMoney(i.status === "paid" ? i.total_minor : i.amount_due_minor ?? i.total_minor, i.currency)}</span>
                  <span className={`zob-chip zpay-chip tone-${tone}`}>{label}</span>
                  <div className="zpay-row-actions">
                    {i.payable && i.id && <button type="button" className="ba-btn primary sm" onClick={() => openInvoice(i.id)}>Pay now</button>}
                    {i.status === "paid" && i.id && <button type="button" className="ba-btn sm" onClick={() => openInvoice(i.id)}>View</button>}
                  </div>
                </li>
              );
            })}
          </ul>
        )}
      </section>

      {Array.isArray(overview?.packs) && overview.packs.length > 0 && (
        <section className="zpay-card" aria-labelledby="zpay-packs">
          <h3 id="zpay-packs">Add ons</h3>
          <p className="zob-muted">One time, for this month. Charged to your saved card.</p>
          <ul className="zpay-list">
            {overview.packs.map((p) => (
              <li key={p.code} className="zpay-row">
                <div className="zpay-row-main"><strong>{Number(p.quantity).toLocaleString("en-US")} {RES[p.resource] ?? p.resource}</strong></div>
                <span className="zpay-amount">{formatMoney(p.price_cents, "usd")}</span>
                <div className="zpay-row-actions"><button type="button" className="ba-btn sm" onClick={() => openPack(p)}>Buy</button></div>
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
// Add ons (owner, 27 Nov 2026): Stripe can't add items to a finalized invoice, so ticked packs are separate receipt lines,
// "Add ons are charged separately right after your plan payment": once the server confirms the plan payment, each is
// bought through the pack path with its own key (made when Pay is pressed, kept on retry and reload). The invoice is
// never charged again; a pack that fails says "Plan paid. 100 minutes not added", with Try again for that pack only.
const safeUrl = (u) => (typeof u === "string" && /^https:\/\/[^\s"'<>]+$/.test(u) ? u : null);
const ADDON_NOTE = "Add ons are charged right after your plan";
export function InvoiceCheckout({ api, invoiceId, onBack, onUpdateCard, backLabel = "All invoices", businessId = null, onInvoice, onSettled, returned = false, onOpenPack }) {
  const [inv, setInv] = useState({ status: "loading" });
  const [paidBefore, setPaidBefore] = useState(false);
  // Auto pay (owner, 27 Nov 2026): on by default; starts from what Stripe has; the switch's value words the agreement and a
  // change goes to the server with the payment's start (review M2)
  const [ap, setAp] = useState(null);
  const [apOn, setApOn] = useState(true);
  const [apNote, setApNote] = useState("");
  const apSent = useRef(null);   // the last Auto pay value the server has from this page: from the loaded status, then each change sent (review)
  const businessOf = inv.status === "ok" ? inv.invoice?.business_id : null;
  const [plan, setPlan] = useState(null);
  const [offer, setOffer] = useState([]);
  const [selected, setSelected] = useState([]);
  useEffect(() => {
    if (!businessOf || !api.overview) return undefined;
    let alive = true;
    api.overview(businessOf).then((o) => { if (alive) setPlan(o?.plan ?? null); }, () => {});
    if (api.addonCatalog) api.addonCatalog(businessOf).then((c) => { if (alive) setOffer(offerFrom(c)); }, () => {});
    return () => { alive = false; };
  }, [api, businessOf]);
  useEffect(() => {
    if (!businessOf || !api.autopayStatus) return undefined;
    let alive = true;
    api.autopayStatus(businessOf).then((a) => { if (alive && a && typeof a.on === "boolean") { setAp(a); setApOn(a.on); apSent.current = a.on; } }, () => {});
    return () => { alive = false; };
  }, [api, businessOf]);
  // ---- the add ons after the plan payment ----
  const [items, setItems] = useState([]);
  const [buying, setBuying] = useState(false);
  const run = useRef(false);   // one run at a time (a double click on Try again, a reload's resume and the confirmation together)
  const consentFor = useRef(null);
  const fromList = addonRows;   // the server's "granted" wins over a local failure (review round 3)
  async function settleAddons(only = null) {
    if (run.current) return;
    run.current = true; setBuying(true);
    const local = {};
    try {
      let fresh = await api.invoiceStatus(invoiceId);
      consentFor.current = fresh?.addons_consent ?? consentFor.current;
      if (fresh?.status !== "paid" || !Array.isArray(fresh?.addons) || !fresh.addons.length) { setItems(fromList(fresh?.addons)); return; }
      // the business the server named for this invoice (the status just read), then the page's own; the server checks
      // the owner either way (review round 3)
      const biz = (typeof fresh?.business_id === "string" && /^[0-9a-f-]{36}$/i.test(fresh.business_id) ? fresh.business_id : null) ?? businessOf ?? businessId;
      for (const a of fresh.addons) {
        if (only && a.code !== only) continue;
        const step = addonStep(a);
        if (step !== "todo" && !(only && step === "failed")) continue;
        try { await api.packBuy(biz, a.code, a.key, { invoiceId, consentHash: consentFor.current }); }
        catch (err) {
          // a lost answer: the same key is kept and reaches the same purchase on Try again (never a second charge)
          local[a.code] = { step: "failed", words: /fetch|network|load failed/i.test(String(err?.message ?? "")) || err?.status === undefined && !err?.code
            ? "We couldn't confirm this pack. Try again uses the same payment, never a second charge." : `${words(err)}` };
        }
      }
      for (let i = 0; i < 8; i++) {
        fresh = await api.invoiceStatus(invoiceId);
        const now = fromList(fresh?.addons, local);
        setItems(now);
        const waiting = now.filter((a) => a.step === "adding" && a.purchase_id);
        if (!waiting.length && !now.some((a) => a.step === "todo")) break;
        await new Promise((r) => setTimeout(r, 900 * (i + 1)));
        // each pack's own status (the server applies Stripe's events there), as the pack page asks
        for (const a of waiting) await api.packStatus(biz, a.purchase_id).catch(() => null);
      }
      fresh = await api.invoiceStatus(invoiceId);
      setItems(fromList(fresh?.addons, local));
    } catch (err) { setItems((cur) => cur.map((a) => (a.step === "added" ? a : { ...a, step: "failed", words: words(err) }))); }
    finally { run.current = false; setBuying(false); }
  }
  function retryAddon(a) {
    // a card the bank declined or wants confirmed: that pack's own page (Pay with another card, or Confirm with your bank)
    if (a.purchase_id && a.can_act && onOpenPack) return onOpenPack(a.code, a.purchase_id);
    return settleAddons(a.code);
  }
  function onPayment(p) { if (p?.status === "confirmed") { onSettled?.(); settleAddons(); } }
  const apKey = useRef(newKey());
  const due = inv.status === "ok" ? Number(inv.invoice?.amount_due_minor) : 0;
  const addonMinor = addonsTotal(offer, selected);
  const renewal = inv.status === "ok" ? inv.invoice?.renewal_minor ?? plan?.price_cents : null;
  // the plan on this card, the add ons on the saved card right after (owner, 27 Nov 2026: the words say which card)
  const consent = inv.status === "ok" ? invoiceConsent({ planMinor: due, addonsMinor: addonMinor, autopay: apOn, renewalMinor: renewal }) : null;
  // submit: the Pay press, right before Stripe takes the payment (the add ons bought after it are this agreement's)
  async function startPay(submit = false) {
    const keys = addonKeys(`zella.addonkeys.${invoiceId}`, selected);
    const changed = ap && apSent.current !== null && apOn !== apSent.current;
    const r = await api.invoiceStart(invoiceId, { autopay: apOn, ...(changed ? { autopayKey: `${apKey.current}${apOn ? "on" : "off"}` } : {}),   // one key per value
      addons: selected.map((code) => ({ code, key: keys[code] })), consentHash: await consentHash(consent), submit });
    if (changed) {
      if (!r?.autopay_error) apSent.current = apOn;
      setApNote(r?.autopay_error ? `Auto pay wasn't changed. ${r.autopay_error === "NO_SAVED_CARD" ? "It needs a working saved card: update your card first." : "Please try again in Payments."}`
        : apOn ? "Auto pay is on: Stripe charges your saved card on each renewal date." : `Auto pay is off. ${autopayWords(ap.email_live === true).offText}`);
    }
    return r;
  }
  useEffect(() => {
    let alive = true;
    api.invoiceStatus(invoiceId).then((i) => {
      if (!alive) return;
      // an invoice of another business than this workspace: the same answer as one that doesn't exist
      if (businessId && i?.business_id !== businessId) return setInv({ status: "error", error: { code: "NOT_FOUND", words: "We couldn't find that for your account. Check you're signed in as the business owner." } });
      setInv({ status: "ok", invoice: i }); setPaidBefore(i?.status === "paid"); onInvoice?.(i);
      if (i?.status === "paid") { onSettled?.(); if (Array.isArray(i.addons) && i.addons.length) { setItems(fromList(i.addons)); settleAddons(); } }   // a reload mid way resumes the add ons
    },
      (err) => { if (alive) setInv({ status: "error", error: err }); });
    return () => { alive = false; };
  }, [api, invoiceId]); // eslint-disable-line react-hooks/exhaustive-deps
  // one object per server answer: the checkout follows the server's state when it changes, never on a re-render
  const payment = useMemo(() => (inv.status === "ok" ? invoiceAsPayment(inv.invoice) : null), [inv]);
  const back = onBack && <button type="button" className="ba-link zob-back" onClick={onBack}><Icon name="arrow_back" size="sm" /> {backLabel}</button>;
  if (inv.status === "loading") return <>{back}<p className="zpay-loading" role="status">Loading the invoice…</p></>;
  if (inv.status === "error") return <>{back}<div className="zob-state zob-state-box error" role="alert"><Icon name="error" /><div><strong>We couldn't open this invoice</strong><p>{words(inv.error)}</p></div></div></>;
  const i = inv.invoice;
  const cannot = !i.payable && i.status !== "paid";
  // a simple summary (owner, 27 Nov 2026): the plan and what the payment covers; the invoice number and details stay in the PDF
  const span = i.period_start ? `${shortDay(i.period_start)} to ${shortDay(i.period_end)}` : day(i.created_at);
  const summary = {
    title: plan?.tier ? `Your ${planName(plan.tier)} plan` : "Your plan", subtitle: span,
    lines: [...(i.status !== "paid" ? [["Plan", formatMoney(i.amount_due_minor, i.currency), "workspace_premium"]] : []),
      ...(Number(i.amount_paid_minor) > 0 ? [["Paid", formatMoney(i.amount_paid_minor, i.currency), "task_alt"]] : [])],
    totalLabel: i.status === "paid" ? "Due now" : "Due today", amountMinor: i.status === "paid" ? i.amount_due_minor : due + addonMinor, currency: i.currency,
  };
  const over = {
    ...(paidBefore ? { confirmed: { label: "This is paid", body: `Paid on ${day(i.paid_at)}. Nothing more is due.` } } : {}),
    off: cannot && i.payments_live !== false ? { label: "This can't be paid online", body: "Contact Zella Voice support if this looks wrong." }
      : { label: "Paying online isn't on yet", body: "Your saved card is charged on the renewal date." },
  };
  return (
    <div className="zpay-checkout">
      {back}
      <GlassCheckout summary={summary} payment={payment} words={over} payLabel={(a) => `Pay ${a}`} onUpdateCard={onUpdateCard} returned={returned}
        fallbackUrl={i.status !== "paid" ? safeUrl(i.hosted_invoice_url) : null} onPayment={onPayment}
        autopay={ap && !paidBefore ? { on: apOn, onChange: setApOn, ...autopayWords(ap.email_live === true, "your saved card") } : null}
        addons={!paidBefore && i.payable ? { offer, selected, onChange: (code, on) => setSelected((cur) => toggle(cur, code, on)), note: ADDON_NOTE } : null}
        consentText={consent}
        start={() => startPay(false)} beforeSubmit={() => startPay(true)}
        confirm={async () => {
          const r = await api.invoiceReturn(invoiceId);
          const p = invoiceAsPayment(r.invoice);
          // still payable and Stripe has no payment for it: say so, and let the owner pay again without a reload (review)
          return { payment: p, card: r.card, ...(fromServer(p).state === "idle" ? { stopped: "not_taken" } : {}) };
        }}
        kind="intent" saveNote="This card is used for this payment only."
        after={<AddonProgress items={items} onRetry={retryAddon} busy={buying} />}
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

// Buying a pack: charged to the saved card with our Pay button (no form), after the owner ticks "I agree" for its own
// amount. If the bank wants to confirm, or the saved card is declined, Stripe's card fields open in the same panel on the
// pack's own PaymentIntent. Added only when the server confirms it. The receipt is the same panel as Pay now's.
export function PackCheckout({ api, businessId, pack, card, onBack, onUpdateCard, onSettled, purchaseId = null, onPurchase, returned = false }) {
  const key = useRef(newKey());
  const purchase = useRef(purchaseId);
  // a purchase already made (named in the address): the server's answer, never a new Pay (double payment cases 1, 2, 8)
  const [payment] = useState(() => (purchaseId ? { status: "waiting", reason: "processing" } : { status: "waiting", checkout_available: true }));
  const which = cardLine(card);
  const label = `${Number(pack.quantity).toLocaleString("en-US")} ${RES[pack.resource] ?? pack.resource}`;
  const consent = packConsent(pack.price_cents);
  const summary = {
    title: label, subtitle: "One time, for this month.",
    lines: [[label, formatMoney(pack.price_cents, "usd"), "inventory_2"], ["Charged to", which ?? "your saved card", "credit_card"]],
    totalLabel: "Due today", amountMinor: pack.price_cents, currency: "usd",
  };
  return (
    <div className="zpay-checkout">
      {onBack && <button type="button" className="ba-link zob-back" onClick={onBack}><Icon name="arrow_back" size="sm" /> Back to payments</button>}
      <GlassCheckout summary={summary} payment={payment} payLabel={`Pay ${formatMoney(pack.price_cents, "usd")}`} consentText={consent}
        detailsNote={which ? `We'll charge your saved ${which}.` : "We'll charge your saved card."}
        words={{ confirmed: { label: `${label} added`, body: "Thank you. It's ready to use." },
          // the purchase may have reached Stripe before the connection dropped: its state is unknown, never "you weren't charged" (review)
          network: { label: "We couldn't confirm your payment yet", body: "Please don't pay again; check Billing and subscription in a moment.", action: "Try again" } }}
        onUpdateCard={onUpdateCard}
        start={async () => {
          // a lost reply or a 5xx keeps the key: Try again asks for the SAME purchase, never a second charge (M1)
          try { const r = await api.packBuy(businessId, pack.code, key.current, { consentHash: await consentHash(consent) }); purchase.current = r.purchase_id; onPurchase?.(r.purchase_id); return { status: "processing" }; }
          catch (err) { if (keyIsSpent(err)) key.current = newKey(); throw err; }
        }}
        actStart={async () => api.packActStart(businessId, purchase.current, { consentHash: await consentHash(consent) })}
        confirm={async () => {
          const r = await api.packStatus(businessId, purchase.current);
          // a cancelled purchase is final: Try again makes a new one with a new key (the old key would only show it again)
          if (r?.purchase?.status === "cancelled") key.current = newKey();
          return { ...packAnswer(r.purchase), card: r.card };
        }}
        onPayment={(p) => { if (p?.status === "confirmed") onSettled?.(); }} returned={returned}
        kind="intent" saveNote="This card is used for this add on only."
        mount={(slots, opts) => (api.mountPayment ? api.mountPayment(slots, { ...opts, purchaseId: purchase.current }) : mountCardFields(slots, opts))} />
    </div>
  );
}
