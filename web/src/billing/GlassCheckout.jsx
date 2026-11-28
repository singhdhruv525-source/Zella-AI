import { forwardRef, useEffect, useLayoutEffect, useReducer, useRef, useState } from "react";
import { ErrorBoundary, Icon } from "../BusinessUI";
import { brandLabel, cardWords, expiredWhileConfirming, ERROR_WORDS, failureKind, formatMoney, fromServer, nextDelay, reduce, WORDS } from "./checkoutMachine";
import { mountCardFields } from "./stripeEmbedded";
import { addonName, chosen } from "./addons.js";
import { declineOf } from "./declines.js";
import { AddonPicker, ConsentBox } from "./ReceiptExtras";
import "./glassCheckout.css";

// The glass checkout (owner, 27 Nov 2026): three panels like a real checkout: the customer's card on the left, a
// "Payment details" panel in the middle with Stripe's own card fields, and the order summary as a receipt on the right
// (the card above the payment panel on a tablet; one column on a phone). Every payment the owner makes uses it: the
// onboarding Pay step (a Checkout Session, ui_mode custom), Pay now for an unpaid invoice and finishing a pack (a
// PaymentIntent), and buying a pack on the saved card (no form, our Pay button).
//
// The card fills in as the owner types, from Stripe's events only (NN-9: the fields are Stripe's frames; this page can't
// read them): the brand as soon as Stripe knows it, a highlight on the part being typed, the card turning over while the
// security code is typed, then "•••• •••• •••• 4242" and "12/28" from Stripe's PaymentMethod preview once every field is
// complete (brand, last 4 and expiry are not the card number). The cardholder name comes from Stripe's billing address
// fields (Address Element) as it is typed, mirrored in capitals; it stays in memory and the address never shows on the card. The card never shows the Zella Voice name.
// After Stripe finishes, the panels blur, the card lifts to the centre while OUR server confirms, and turns the look's
// success colour only when the server confirms, with the issuing bank only as Stripe's card.issuer gives it.
//
// Props:
//   summary      { kicker, title, lines: [[label, value, icon]], totalLabel, amountMinor, currency, footnote, intro }
//   payment      the server's state in the onboarding payment shape ({ status, reason, checkout_available })
//   kind         "checkout" (a Checkout Session's client secret) or "intent" (a PaymentIntent's)
//   start()      asks our server: { status: "open", client_secret, publishable_key, livemode } or { status: "processing" }
//   actStart()   the same, for "Confirm with your bank" or "Pay with another card" on a pack (its own PaymentIntent)
//   confirm()    asks our server again: { payment, card?, stopped? }. The only way to "Payment received".
//   mount        (slots, opts) => Promise<{ destroy, submit, demo? }>; default Stripe's card fields (stripeEmbedded.js)
//   onUpdateCard opens Stripe's card update (for "There's no card to charge")
//   words        per state overrides; payLabel the first button; saveNote a line under the fields
//   autopay      { on, onChange(on), onText, offText }: the "Auto pay" switch (owner, 27 Nov 2026)
//   beforeSubmit () => Promise, run before Stripe confirms (sends the Auto pay choice with the payment)
//   hostedFallback () => start(...) asking for Stripe's own Checkout page, used at once when Stripe.js can't load (onboarding)
//   fallbackUrl  Stripe's hosted invoice page: offered ONLY when Stripe's form can't load or our checkout can't be shown
//   addons       { offer, selected, onChange(code, on), note } (owner, 27 Nov 2026): tick box rows under the receipt; each
//                ticked pack is a receipt line; the parent's summary.amountMinor is the full total (server prices)
//   consentText  the required "I agree" words (paymentConsent.js, from the server's figures): Pay stays disabled until the
//                box is ticked; a change of the words unticks it; start() and beforeSubmit() send their sha256
//   restartKey   the add on selection: a change while Stripe's form is open goes back to Pay (onboarding: one session
//                per selection, the server expires the old one)
//   after        shown under the checkout once paid (Pay now: each add on's progress)
export default function GlassCheckout(props) {
  return (
    <ErrorBoundary resetKey="glass-checkout" fallback={(retry) => (
      <div className="zob-state zob-state-box error" role="alert">
        <Icon name="error" />
        <div><strong>The payment form couldn't be shown</strong><p>You weren't charged. Try again, or come back later.</p><button type="button" className="ba-btn sm" onClick={retry}>Try again</button>
          {props.fallbackUrl && <FallbackLink url={props.fallbackUrl} />}</div>
      </div>
    )}>
      <Checkout {...props} />
    </ErrorBoundary>
  );
}

// the one place Stripe's hosted page is offered: an error fallback (owner, 27 Nov 2026)
function FallbackLink({ url }) {
  return <p className="zgc-fallback"><a className="ba-link" href={url} target="_blank" rel="noopener noreferrer">Pay on Stripe's secure page <Icon name="open_in_new" size="sm" /></a></p>;
}

const reducedMotion = () => typeof window !== "undefined" && window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
const finePointer = () => typeof window !== "undefined" && window.matchMedia?.("(hover: hover) and (pointer: fine)").matches;
const NO_LIVE = { brand: null, focus: null, started: false, numberDone: false, preview: null, name: "", addressDone: false, errors: {}, bank: false };

function liveReduce(s, e) {
  if (e.type === "reset") return NO_LIVE;
  if (e.type === "focus") return { ...s, focus: e.field };
  if (e.type === "blur") return s.focus === e.field ? { ...s, focus: null } : s;
  if (e.type === "preview") return { ...s, preview: e.card ?? null };
  // Stripe's billing address: only the name is kept (memory only, for the card); the address never reaches the card
  if (e.type === "address") return { ...s, name: typeof e.name === "string" ? e.name.slice(0, 80) : "", addressDone: e.complete === true, errors: { ...s.errors, address: typeof e.error === "string" ? e.error : null } };
  // the bank's own check is open (Stripe's overlay; the stand in's preview)
  if (e.type === "bank") return { ...s, bank: e.waiting === true };
  // Stripe's inline words for a wrong field (an invalid number, a date in the past, an incomplete code): under the field
  const errors = e.type === "change" ? { ...s.errors, [e.field]: typeof e.error === "string" ? e.error : null } : s.errors;
  if (e.type === "change" && e.field === "number") return { ...s, errors, brand: e.brand && e.brand !== "unknown" ? e.brand : null, started: !e.empty, numberDone: e.complete === true };
  if (e.type === "change") return { ...s, errors };
  return s;
}

function Checkout({ summary, payment, kind = "checkout", start, actStart, confirm, onPayment, mount, returned = false, payLabel = "Pay securely",
  words: over = {}, onUpdateCard, detailsNote, saveNote, fallbackUrl, autopay, hostedFallback, beforeSubmit, addons = null, consentText = null, restartKey = "", after = null }) {
  const [m, dispatch] = useReducer(reduce, payment, (p) => (returned && fromServer(p).state !== "confirmed" ? { state: "confirming", attempt: 0 } : fromServer(p)));
  const [live, onLive] = useReducer(liveReduce, NO_LIVE);
  const secret = useRef(null);           // { clientSecret, publishableKey, livemode }: memory only, dropped once mounted
  const slots = useRef({});             // the elements Stripe's fields mount into: number, expiry, cvc, address
  const slotRef = (f) => (el) => { slots.current[f] = el; };
  const handle = useRef(null);
  const cardRef = useRef(null), stageCardRef = useRef(null), headingRef = useRef(null);
  const first = useRef(true);
  const alive = useRef(true);            // false only once this component leaves the page
  const [card, setCard] = useState(null);
  const [demo, setDemo] = useState(false);
  const [sending, setSending] = useState(false);
  const [inline, setInline] = useState("");   // a local check's words, under the fields
  // a card declined or the bank's check failed at payment: what Stripe said, in the panel, with Try another card (the
  // same payment is kept: a new card on the same invoice uses the same PaymentIntent)
  const [decline, setDecline] = useState(null);
  const [unknown, setUnknown] = useState(false);   // Stripe didn't answer: the server is asked, never "nothing was charged"
  const [slowBank, setSlowBank] = useState(false);   // a confirm taking a while: most often the bank's own check
  useEffect(() => { alive.current = true; return () => { alive.current = false; }; }, []);
  // the required "I agree" box (owner, 27 Nov 2026): unticked by default; other words (another total, Auto pay changed)
  // untick it, so what was agreed is always what is charged
  const [agreed, setAgreed] = useState(false);
  const [consentError, setConsentError] = useState("");
  const needsConsent = typeof consentText === "string" && consentText.length > 0;
  const lastText = useRef(consentText);
  useEffect(() => {
    if (lastText.current === consentText) return;
    const had = agreed;
    lastText.current = consentText;
    if (had) { setAgreed(false); setConsentError("The total changed. Please tick the box again."); }
  }, [consentText]); // eslint-disable-line react-hooks/exhaustive-deps
  const consentOk = () => {
    if (!needsConsent || agreed) return true;
    setConsentError("Please tick the box to continue.");
    return false;
  };
  // the add ons changed while Stripe's form was open: back to Pay for the new total
  const lastSelection = useRef(restartKey);
  useEffect(() => {
    if (lastSelection.current === restartKey) return;
    lastSelection.current = restartKey;
    if (m.state === "loading" || m.state === "ready") dispatch({ type: "RESET" });
  }, [restartKey]); // eslint-disable-line react-hooks/exhaustive-deps
  // a change of the total is announced politely (not on first view)
  const [totalNote, setTotalNote] = useState("");
  const lastTotal = useRef(summary?.amountMinor);
  useEffect(() => {
    if (lastTotal.current === summary?.amountMinor) return;
    lastTotal.current = summary?.amountMinor;
    setTotalNote(`Total due today ${formatMoney(summary?.amountMinor, summary?.currency)}.`);
  }, [summary?.amountMinor]); // eslint-disable-line react-hooks/exhaustive-deps

  // the server's word moves the machine (it is the only source of "confirmed")
  useEffect(() => { dispatch({ type: "SERVER", payment }); }, [payment]);

  async function begin(which) {
    if (m.state !== "idle" && m.state !== "error") return;
    if (!consentOk()) return;
    dispatch({ type: "PAY" });
    setInline(""); onLive({ type: "reset" });
    try {
      const r = await (which === "act" ? actStart : start)();
      if (r?.status === "processing") return dispatch({ type: "PROCESSING" });
      if (r?.status === "redirect") return goHosted(r.url);
      if (r?.status !== "open" || typeof r.client_secret !== "string") throw Object.assign(new Error("no checkout"), { code: "CHECKOUT_NOT_READY" });
      // with the business's own address to prefill Stripe's billing address fields (the owner can change it there)
      secret.current = { clientSecret: r.client_secret, publishableKey: r.publishable_key, livemode: r.livemode,
        prefill: r.billing_prefill && typeof r.billing_prefill === "object" ? r.billing_prefill : null };
      dispatch({ type: "SECRET" });
    } catch (err) {
      const k = failureKind(err);
      dispatch(k === "already_paid" ? { type: "ALREADY_PAID" } : { type: "FAIL", kind: k, words: k === "refused" ? err?.words ?? err?.message : undefined });
    }
  }
  function errorAction() {
    if (m.kind === "needs_action" || m.kind === "card_declined") return begin("act");
    if (m.kind === "no_card") return onUpdateCard?.();
    dispatch({ type: "RETRY" });
  }
  const submitting = useRef(false);   // a double click or Enter twice before React re-renders: one confirm
  async function submit() {
    if (!handle.current?.submit || sending || submitting.current) return;
    if (!consentOk()) return;
    submitting.current = true;
    setSending(true); setInline(""); setDecline(null);
    const slow = setTimeout(() => { if (alive.current) setSlowBank(true); }, 1500);
    // the choices on this panel (Auto pay) go to the server with the payment, before Stripe takes it (review M2)
    let stage = "ours";
    try { if (beforeSubmit) await beforeSubmit(); stage = "stripe"; await handle.current.submit(); }
    catch (err) {
      if (alive.current && stage === "ours") setInline(`${err?.words ?? err?.message ?? "That didn't work."} You weren't charged.`.replace(/(Nothing was charged|You weren't charged)\. You weren't charged\./, "You weren't charged."));
      else if (alive.current) {
        const d = declineOf(err);
        // Stripe didn't answer: whether it was taken is unknown, so OUR server is asked (the confirming wait)
        if (d?.kind === "unknown") { setUnknown(true); dispatch({ type: "COMPLETE" }); }
        else if (d) setDecline(d);
        else setInline(err?.code === "LOCAL_CHECK" ? err.message : "The payment didn't start. Please try again.");
      }
    }
    finally { clearTimeout(slow); submitting.current = false; if (alive.current) { setSending(false); setSlowBank(false); } }
  }
  async function playDemo() { await handle.current?.demo?.(); }
  async function playInvalid() { await handle.current?.demoInvalid?.(); }
  function anotherCard() { setDecline(null); setInline(""); handle.current?.clear?.(); }
  // Stripe's own page (owner, 27 Nov 2026: the onboarding fallback): only Stripe's checkout address, and the return there
  // proves nothing (the server confirms)
  function goHosted(url) {
    if (typeof url !== "string" || !/^https:\/\/checkout\.stripe\.com\//.test(url)) throw Object.assign(new Error("not Stripe's page"), { code: "CHECKOUT_NOT_READY" });
    dispatch({ type: "PROCESSING" });
    window.location.assign(url);
  }

  // Stripe's card fields: mounted once per "loading" into our slots, destroyed when the flow moves on or the page leaves
  useEffect(() => {
    if (m.state !== "loading" || !secret.current || !slots.current.number) return undefined;
    const opts = { ...secret.current, kind, returnUrl: window.location.href,
      onEvent: (e) => { if (alive.current) onLive(e); },
      onComplete: () => { if (alive.current) dispatch({ type: "COMPLETE" }); } };
    secret.current = null;
    const doMount = mount ?? ((s, o) => mountCardFields(s, o));
    doMount({ ...slots.current }, opts).then(
      (h) => { if (alive.current) { handle.current = h; setDemo(typeof h?.demo === "function"); dispatch({ type: "MOUNTED" }); } else h?.destroy?.(); },
      (err) => {
        if (!alive.current) return;
        const kind = failureKind(err) === "misconfigured" ? "misconfigured" : "stripe_load";
        // Stripe.js couldn't load: where the page has a hosted fallback (the onboarding Pay step), use it at once
        if (kind === "stripe_load" && hostedFallback) {
          hostedFallback().then((r) => { if (r?.status === "redirect") goHosted(r.url); else if (r?.status === "processing") dispatch({ type: "PROCESSING" }); else dispatch({ type: "FAIL", kind }); },
            () => { if (alive.current) dispatch({ type: "FAIL", kind }); });
          return;
        }
        dispatch({ type: "FAIL", kind });
      },
    );
    return undefined;
  }, [m.state]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => {
    if (m.state !== "loading" && m.state !== "ready" && handle.current) { handle.current.destroy?.(); handle.current = null; setDemo(false); }
  }, [m.state]);
  useEffect(() => () => { handle.current?.destroy?.(); handle.current = null; secret.current = null; }, []);

  // confirming: look again with backoff, then calmly once a minute; only the server's answer can confirm
  useEffect(() => {
    const wait = nextDelay(m);
    if (wait == null) return undefined;
    let on = true;
    const t = setTimeout(async () => {
      if (m.state === "pending" && document.visibilityState !== "visible") return dispatch({ type: "STILL_WAITING" });
      try {
        const r = await confirm();
        if (!on) return;
        if (r?.card) setCard(r.card);
        onPayment?.(r?.payment, r?.card ?? null);
        if (r?.stopped) dispatch({ type: "STOPPED", kind: r.stopped, words: r.stoppedWords });
        else if (expiredWhileConfirming(r?.payment)) dispatch({ type: "STOPPED", kind: "expired" });
        else if (fromServer(r?.payment).state === "confirmed") dispatch({ type: "SERVER", payment: r.payment, card: r.card ?? null });
        else dispatch({ type: "STILL_WAITING" });
      } catch (err) { if (on) dispatch({ type: "FAIL", kind: failureKind(err) }); }
    }, wait);
    return () => { on = false; clearTimeout(t); };
  }, [m]); // eslint-disable-line react-hooks/exhaustive-deps

  // the card lifts from its place on the left to the centre (transform only), unless motion is reduced
  const staged = m.state === "confirming" || m.state === "pending" || m.state === "confirmed";
  useLayoutEffect(() => {
    const from = cardRef.current, to = stageCardRef.current;
    if (!staged || !from || !to || reducedMotion()) return;
    if (to.dataset.flown === "1") return;
    const a = from.getBoundingClientRect(), b = to.getBoundingClientRect();
    if (!a.width || !b.width) return;
    to.style.setProperty("--zgc-dx", `${a.left + a.width / 2 - (b.left + b.width / 2)}px`);
    to.style.setProperty("--zgc-dy", `${a.top + a.height / 2 - (b.top + b.height / 2)}px`);
    to.style.setProperty("--zgc-scale", String(a.width / b.width));
    to.dataset.flown = "1";
    to.closest(".zgc-stage-card")?.classList.add("zgc-fly");
  }, [staged]);

  // one heading takes focus when the state changes (not on first view), so keyboard and screen reader users follow
  useEffect(() => {
    if (first.current) { first.current = false; return; }
    if (m.state === "ready") return;   // the next Tab goes into the card fields; don't pull focus away from them
    headingRef.current?.focus({ preventScroll: false });
  }, [m.state, m.kind]);

  const base = m.state === "error" ? ERROR_WORDS[m.kind] ?? ERROR_WORDS.server : WORDS[m.state] ?? WORDS.off;
  const words = { ...base, ...(over[m.state === "error" ? m.kind : m.state] ?? {}),
    ...(m.state === "error" && m.kind === "refused" && m.words ? { body: `${m.words} You weren't charged.` } : {}),
    ...(m.state === "error" && m.kind !== "refused" && m.words ? { body: m.words } : {}),
    ...(m.state === "confirming" && unknown ? { label: "Checking your payment…", body: "We couldn't confirm your payment yet. Please don't pay again; we'll update this page." } : {}),
    ...(m.state === "ready" && (live.bank || (sending && slowBank)) ? { label: "Waiting for your bank to confirm…", body: "Approve the payment in your bank's window. Keep this page open." } : {}) };
  const server = m.state === "confirmed" ? cardWords(m.card ?? card) : null;
  // what the card shows: only Stripe's events and preview, the server's answer, and the name from Stripe's billing address
  const view = {
    brand: server?.brand ?? brandLabel(live.preview?.brand ?? live.brand),
    last4: server?.last4 ?? live.preview?.last4 ?? null,
    exp: live.preview?.exp ?? null,
    issuer: server?.issuer ?? null,
    name: live.name.trim().toUpperCase(),
    focus: m.state === "ready" ? live.focus : null,
    typing: m.state === "ready" && live.focus === "number" && live.started && !live.numberDone,
  };
  const amountKnown = summary?.amountMinor !== null && summary?.amountMinor !== undefined && summary?.amountMinor !== "" && Number.isFinite(Number(summary?.amountMinor));
  const amount = formatMoney(summary?.amountMinor, summary?.currency);
  const totalLabel = m.state === "off" || m.state === "locked" ? "Due when payment opens" : summary?.totalLabel ?? "Due today";
  const tone = m.state === "confirmed" ? "good" : m.state === "error" ? "urgent" : m.state === "pending" ? "heads" : "info";
  const formOpen = m.state === "loading" || m.state === "ready";
  const picked = addons ? chosen(addons.offer ?? [], addons.selected ?? []) : [];
  const lines = [...(summary?.lines ?? []), ...picked.map((a) => [addonName(a), formatMoney(a.price_cents, "usd"), "add_circle"])];
  const actKinds = m.state === "error" && (m.kind === "needs_action" || m.kind === "card_declined");
  const consentShown = needsConsent && (["idle", "submitting", "loading", "ready"].includes(m.state) || actKinds);
  const blocked = needsConsent && !agreed;   // Pay looks disabled and says why when pressed (the box is the reason)
  const idleLabel = typeof payLabel === "function" ? payLabel(amount) : payLabel;
  return (
    <section className={`zgc is-${m.state}${m.state === "ready" && (live.bank || (sending && slowBank)) ? " is-bankwait" : ""}`} aria-labelledby="zgc-status">
      <div className={`zob-status tone-${tone} zgc-status`}>
        <span className="ba-icon" aria-hidden="true">{{ confirmed: "paid", locked: "lock", off: "schedule", idle: "credit_card", submitting: "hourglass_top", loading: "hourglass_top", ready: "lock", confirming: "hourglass_top", pending: "schedule", error: "error" }[m.state]}</span>
        <div>
          <h2 id="zgc-status" ref={headingRef} tabIndex={-1}>{words.label}</h2>
          <p>{words.body}</p>
        </div>
      </div>
      {/* one live region for every change people need to hear about */}
      <p className="zob-sr" aria-live="polite" role="status">{m.state === "idle" || m.state === "off" || m.state === "locked" ? "" : `${words.label}. ${words.body}`}</p>

      <div className="zgc-stage-wrap">
        <div className="zgc-grid" aria-hidden={staged ? "true" : undefined} inert={staged ? true : undefined}>
          <div className="zgc-cardcol">
            <CardArt ref={cardRef} view={view} confirmed={false} tilt />
            <p className="zgc-cardcol-note"><Icon name="visibility_off" size="sm" /> We never see your full card number.</p>
          </div>

          <div className="zgc-panel zgc-pay" aria-labelledby="zgc-pay-title">
            <div className="zgc-pay-head">
              <h3 id="zgc-pay-title">Payment details</h3>
              {demo && <span className="zgc-mock-badge">Preview of Stripe's form</span>}
            </div>
            {demo && <p className="zob-sr">Preview only. On the live site the card fields are Stripe's own secure fields. This local preview never loads Stripe and takes no card.</p>}
            <div className="zgc-form">
              {/* no intro paragraph (owner, 27 Nov 2026): the receipt says what is paid */}
              {detailsNote && (m.state === "idle" || m.state === "submitting") && <p className="zgc-details-note">{detailsNote}</p>}
              {(m.state === "off" || m.state === "locked") && <p className="zob-muted">{m.state === "off" ? "Nothing is charged until payment opens here." : "Payment opens once your identity is verified."}</p>}
              {formOpen && (
                <div className={`zgc-fields${m.state === "loading" ? " is-loading" : ""}`}>
                  {[["number", "Card number", true], ["expiry", "Expiration", false], ["cvc", "Security code", false]].map(([f, label, wide]) => (
                    <div key={f} className={`zgc-field${wide ? " wide" : ""}${live.focus === f ? " is-focus" : ""}`}>
                      <span className="zgc-label" id={`zgc-l-${f}`}>{label}</span>
                      <div ref={slotRef(f)} className={`zgc-input zgc-slot${live.errors[f] ? " has-error" : ""}`} data-field={f} />
                      <p className="zgc-field-error" id={`zgc-e-${f}`} aria-live="polite">{live.errors[f] ?? ""}</p>
                    </div>
                  ))}
                  {/* Stripe's Address Element (mode billing): full name and billing address, any country, the United States first */}
                  <div className="zgc-field wide zgc-address" role="group" aria-labelledby="zgc-l-address">
                    <span className="zgc-label" id="zgc-l-address">Billing address</span>
                    <div ref={slotRef("address")} className="zgc-addr-slot" data-field="address" />
                    <p className="zgc-field-error" id="zgc-e-address" aria-live="polite">{live.errors.address ?? ""}</p>
                  </div>
                  {saveNote && <p className="zgc-save-note"><Icon name="bookmark" size="sm" /> {saveNote}</p>}
                </div>
              )}
              {autopay && ["idle", "submitting", "loading", "ready"].includes(m.state) && (
                <div className="zgc-autopay">
                  <div className="zgc-autopay-row">
                    <span className="zgc-autopay-label" id="zgc-autopay-label">Auto pay</span>
                    <button type="button" role="switch" aria-checked={autopay.on} aria-labelledby="zgc-autopay-label" aria-describedby="zgc-autopay-note"
                      className={`ba-switch${autopay.on ? " on" : ""}`} disabled={sending} onClick={() => autopay.onChange(!autopay.on)}><span /></button>
                  </div>
                  <p className="zgc-autopay-note" id="zgc-autopay-note">{autopay.on ? autopay.onText : autopay.offText}</p>
                </div>
              )}
              {m.state === "ready" && inline && <p className="ba-error" role="alert">{inline}</p>}
              {m.state === "ready" && decline && (
                <div className="zgc-decline" role="alert">
                  <span className="ba-icon" aria-hidden="true">{decline.kind === "bank_failed" ? "gpp_bad" : "credit_card_off"}</span>
                  <div><strong>{decline.title}</strong><p>{decline.body}</p>
                    <button type="button" className="ba-btn sm" onClick={anotherCard}>Try another card</button></div>
                </div>
              )}
            </div>
            <div className="zgc-pay-foot">
              {consentShown && <ConsentBox id="zgc-consent" text={consentText} agreed={agreed} error={consentError}
                onChange={(v) => { setAgreed(v); if (v) setConsentError(""); }} />}
              {(m.state === "idle" || m.state === "submitting") && (
                <button type="button" className={`ba-btn primary zgc-pay-btn${blocked ? " is-blocked" : ""}`} disabled={m.state === "submitting"} aria-disabled={blocked ? "true" : undefined}
                  aria-describedby={consentShown ? "zgc-consent-e" : undefined} onClick={() => begin("start")}>
                  <Icon name="lock" size="sm" /> {m.state === "submitting" ? "Opening the card form…" : idleLabel}
                </button>
              )}
              {m.state === "ready" && demo && !live.preview && (
                <button type="button" className="ba-btn zgc-pay-btn" onClick={playDemo}><Icon name="play_arrow" size="sm" /> Fill with Stripe's test card</button>
              )}
              {m.state === "ready" && demo && !live.preview && handle.current?.demoInvalid && (
                <button type="button" className="ba-btn zgc-pay-btn" onClick={playInvalid}><Icon name="error" size="sm" /> Show wrong card details</button>
              )}
              {formOpen && (
                <button type="button" className={`ba-btn primary zgc-pay-btn${blocked ? " is-blocked" : ""}`} disabled={m.state !== "ready" || sending || !live.preview || !live.addressDone}
                  aria-disabled={blocked ? "true" : undefined} aria-describedby={consentShown ? "zgc-consent-e" : undefined} onClick={submit}>
                  <Icon name="lock" size="sm" /> {sending ? "Paying…" : `Pay ${amount}`}
                </button>
              )}
              {m.state === "error" && words.action && (
                <button type="button" className={`ba-btn primary zgc-pay-btn${actKinds && blocked ? " is-blocked" : ""}`} aria-disabled={actKinds && blocked ? "true" : undefined}
                  aria-describedby={actKinds && consentShown ? "zgc-consent-e" : undefined} onClick={errorAction}>{words.action}</button>
              )}
              {m.state === "error" && m.kind === "stripe_load" && fallbackUrl && <FallbackLink url={fallbackUrl} />}
              {m.state === "error" && m.kind === "card_declined" && onUpdateCard && (
                <button type="button" className="ba-btn zgc-pay-btn" onClick={onUpdateCard}>Update saved card</button>
              )}
              <p className="zgc-trust">
                <span><Icon name="lock" size="sm" /> Secured by Stripe</span>
              </p>
            </div>
          </div>

          <aside className="zgc-panel zgc-summary" aria-labelledby="zgc-summary-title">
            {summary?.kicker && <span className="zob-kicker">{summary.kicker}</span>}
            <h3 id="zgc-summary-title">{summary?.title ?? "Your plan"}</h3>
            {summary?.subtitle && <p className="zgc-summary-sub">{summary.subtitle}</p>}
            <dl className="zgc-lines">
              {lines.map(([label, value, icon]) => (
                <div key={label}>
                  <dt>{icon && <span className="zgc-line-icon" aria-hidden="true"><Icon name={icon} size="sm" /></span>}{label}</dt>
                  <dd>{value}</dd>
                </div>
              ))}
            </dl>
            {amountKnown && <div className="zgc-total"><span>{totalLabel}</span><strong>{amount}</strong></div>}
            {picked.length > 0 && <p className="zgc-addon-onetime"><Icon name="info" size="sm" /> {addons?.note ? `${addons.note}.` : "Add ons are one time."}</p>}
            <p className="zob-sr" aria-live="polite">{totalNote}</p>
            {summary?.footnote && <p className="zob-hint">{summary.footnote}</p>}
            {addons && (addons.offer === null || (addons.offer ?? []).length > 0) && m.state !== "confirmed" && !staged && (
              <AddonPicker offer={addons.offer} selected={addons.selected ?? []} onChange={addons.onChange} onRetry={addons.onRetry} locked={m.state === "submitting" || sending} />
            )}
          </aside>
        </div>

        {staged && (
          <div className="zgc-stage" aria-hidden="true">
            <div className="zgc-stage-card">
              <span className="zgc-floor" />
              <span className="zgc-glow" />
              <CardArt ref={stageCardRef} view={{ ...view, focus: null, typing: false }} confirmed={m.state === "confirmed"} big />
            </div>
            {m.state !== "confirmed" && (
              <svg className="zgc-ring" viewBox="0 0 40 40" width="40" height="40"><circle className="zgc-ring-track" cx="20" cy="20" r="16" /><circle className="zgc-ring-arc" cx="20" cy="20" r="16" /></svg>
            )}
            <p className="zgc-stage-caption">{m.state === "confirmed" ? words.label : m.state === "pending" ? "Still confirming" : unknown ? "Checking your payment…" : "Confirming your payment"}</p>
          </div>
        )}
      </div>
      {after}
    </section>
  );
}

// ---------- the card picture ----------
// A gold EMV chip: segmented contacts, a highlight and a shadow (tokens --zella-metal-1..3).
let chipSeq = 0;
function Chip() {
  const [gid] = useState(() => `zgc-chip-${++chipSeq}`);
  return (
    <svg className="zgc-chip" viewBox="0 0 50 38" width="50" height="38">
      <defs>
        <linearGradient id={`${gid}-m`} x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" className="zgc-metal-1" /><stop offset="0.35" className="zgc-metal-2" /><stop offset="0.55" className="zgc-metal-1" /><stop offset="1" className="zgc-metal-3" />
        </linearGradient>
        <radialGradient id={`${gid}-h`} cx="0.3" cy="0.25" r="0.6"><stop offset="0" className="zgc-chip-shine" /><stop offset="1" stopOpacity="0" className="zgc-chip-shine" /></radialGradient>
      </defs>
      <rect x="0.75" y="0.75" width="48.5" height="36.5" rx="6.5" fill={`url(#${gid}-m)`} className="zgc-chip-edge" />
      <path className="zgc-chip-pads" d="M0.75 12.5h14M0.75 25.5h14M35.25 12.5h14M35.25 25.5h14M14.75 0.75v11.75M35.25 0.75v11.75M14.75 25.5v11.75M35.25 25.5v11.75M14.75 12.5c4 3 4 10 0 13M35.25 12.5c-4 3 -4 10 0 13M20 0.75v8M30 0.75v8M20 37.25v-8M30 37.25v-8M20 8.75h10a3.5 3.5 0 0 1 3.5 3.5v13.5a3.5 3.5 0 0 1-3.5 3.5h-10a3.5 3.5 0 0 1-3.5-3.5v-13.5a3.5 3.5 0 0 1 3.5-3.5z" />
      <rect x="0.75" y="0.75" width="48.5" height="36.5" rx="6.5" fill={`url(#${gid}-h)`} />
    </svg>
  );
}
function Contactless() {
  return (
    <svg className="zgc-contactless" viewBox="0 0 24 24" width="24" height="24">
      <path d="M8 8.5a5 5 0 0 1 0 7M11.5 6a8.5 8.5 0 0 1 0 12M15 3.5a12 12 0 0 1 0 17" />
    </svg>
  );
}
// pointer (or device) tilt with a highlight that follows it; never with reduced motion
function useTilt(enabled) {
  const ref = useRef(null);
  useEffect(() => {
    const el = ref.current;
    if (!enabled || !el || reducedMotion()) return undefined;
    const set = (x, y) => {   // x, y in 0..1
      el.style.setProperty("--zgc-rx", `${((0.5 - y) * 12).toFixed(2)}deg`);
      el.style.setProperty("--zgc-ry", `${((x - 0.5) * 18).toFixed(2)}deg`);
      el.style.setProperty("--zgc-sx", `${((x - 0.5) * 100).toFixed(1)}%`);
      el.style.setProperty("--zgc-sy", `${((y - 0.5) * 100).toFixed(1)}%`);
      el.classList.add("is-tilting");
    };
    const leave = () => { el.classList.remove("is-tilting"); ["--zgc-rx", "--zgc-ry", "--zgc-sx", "--zgc-sy"].forEach((k) => el.style.removeProperty(k)); };
    if (finePointer()) {
      const move = (e) => { if (e.pointerType && e.pointerType !== "mouse") return; const r = el.getBoundingClientRect(); set((e.clientX - r.left) / r.width, (e.clientY - r.top) / r.height); };
      el.addEventListener("pointermove", move); el.addEventListener("pointerleave", leave);
      return () => { el.removeEventListener("pointermove", move); el.removeEventListener("pointerleave", leave); };
    }
    // a phone held at an angle: the highlight follows the tilt (where the browser shares it without asking)
    const orient = (e) => { if (e.beta == null || e.gamma == null) return; set(Math.min(1, Math.max(0, 0.5 + e.gamma / 60)), Math.min(1, Math.max(0, 0.5 + (e.beta - 45) / 60))); };
    window.addEventListener("deviceorientation", orient);
    return () => window.removeEventListener("deviceorientation", orient);
  }, [enabled]);
  return ref;
}
function Front({ view, done }) {
  const number = view.last4 ? `•••• •••• •••• ${view.last4}` : "•••• •••• •••• ••••";
  return (
    <>
      <div className="zgc-cf-top"><span className="zgc-cf-issuer">{done ? view.issuer ?? "" : ""}</span>{done && <svg className="zgc-check" viewBox="0 0 36 36" width="36" height="36"><circle cx="18" cy="18" r="16" /><path d="M11 18.5l5 5 9.5 -10.5" /></svg>}</div>
      <div className="zgc-cf-mid"><Chip /><Contactless /></div>
      <div className={`zgc-cf-number zgc-emboss${view.focus === "number" ? " is-focus" : ""}${view.typing ? " is-typing" : ""}`}>{number}</div>
      <div className="zgc-cf-bottom">
        <span className={`zgc-cf-name zgc-emboss${view.focus === "name" ? " is-focus" : ""}`}>{view.name || "CARDHOLDER NAME"}</span>
        <span className={`zgc-cf-valid${view.focus === "expiry" ? " is-focus" : ""}`}><small>VALID<br />THRU</small><span className="zgc-emboss">{view.exp ?? "••/••"}</span></span>
        <span className="zgc-cf-brand">{view.brand ?? ""}</span>
      </div>
    </>
  );
}
function CardArtInner({ view, confirmed, big, tilt }, ref) {
  const tiltRef = useTilt(tilt);
  const back = !confirmed && view.focus === "cvc";
  return (
    <div ref={ref} className={`zgc-card${big ? " big" : ""}${confirmed ? " ok" : ""}${tilt ? " tilt" : ""}${back ? " is-back" : ""}`} aria-hidden="true">
      <span className="zgc-card-shadow" />
      <div ref={tiltRef} className="zgc-card-tiltbox">
        <div className="zgc-card-inner">
          <span className="zgc-card-edge" />
          <div className="zgc-card-face zgc-card-front">
            <Front view={view} done={false} />
            <span className="zgc-card-holo" /><span className="zgc-card-grain" /><span className="zgc-card-spec" /><span className="zgc-card-shimmer" />
          </div>
          {/* the success colours over the front, faded in when the server confirms */}
          <div className="zgc-card-face zgc-card-done">
            <Front view={view} done />
            <span className="zgc-card-grain" />
          </div>
          <div className="zgc-card-face zgc-card-back">
            <span className="zgc-cb-stripe" />
            <div className="zgc-cb-sig"><span className="zgc-cb-panel">AUTHORIZED SIGNATURE</span><span className={`zgc-cb-cvc${back ? " is-focus" : ""}`}>•••</span></div>
            <span className="zgc-cb-note">Security code on the back, typed only into Stripe's field.</span>
            <span className="zgc-card-grain" />
          </div>
        </div>
      </div>
    </div>
  );
}
const CardArt = forwardRef(CardArtInner);
