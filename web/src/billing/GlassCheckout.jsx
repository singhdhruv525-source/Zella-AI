import { forwardRef, useEffect, useLayoutEffect, useReducer, useRef, useState } from "react";
import { ErrorBoundary, Icon } from "../BusinessUI";
import { cardWords, ERROR_WORDS, failureKind, formatMoney, fromServer, nextDelay, reduce, WORDS } from "./checkoutMachine";
import { mountEmbeddedCheckout } from "./stripeEmbedded";
import "./glassCheckout.css";

// The glass checkout (owner, 27 Nov 2026): a payment panel with Stripe's own Embedded Checkout form and an order
// summary side by side, in whichever Zella Voice look is on (tokens only). After Stripe finishes, the panels soften
// behind a frosted layer, the card moves to the centre while we confirm with OUR server, and turns the look's success
// colour only when the server confirms a verified, bound payment. Reusable: the onboarding Pay step uses it today; the
// Pay now link for an unpaid invoice is designed to use it too (docs/PAYMENTS_ARCHITECTURE.md §6.2a, not built).
//
// Card data never touches this code (NN-9): the card is typed only into Stripe's frame, which this page can't read.
// The card picture never shows digits before payment, and afterwards only the brand and last 4 the server returns.
//
// Props:
//   summary      { kicker, title, lines: [[label, value]], totalLabel, amountMinor, currency, footnote }  from the server
//   payment      the server's payment state (zella_owner_onboarding_payment_status); starts and updates the machine
//   start()      asks our server for the checkout: { status: "open", client_secret, publishable_key, livemode } or
//                { status: "processing" }. Throws { code } on a refusal.
//   confirm()    asks our server to look again: { payment, card? }. The only way to "Payment received".
//   onPayment    (payment, card) when the server answered, so the page around it can follow
//   mount        optional (el, opts) => Promise<{ destroy }>; the stand in api passes its own, so Stripe.js is never
//                loaded there. Default: Stripe.js Embedded Checkout.
//   returned     true when the page opened from Stripe's return_url (a redirect payment method)
//   payLabel     the main button's words
export default function GlassCheckout(props) {
  return (
    <ErrorBoundary resetKey="glass-checkout" fallback={(retry) => (
      <div className="zob-state zob-state-box error" role="alert">
        <Icon name="error" />
        <div><strong>The payment form couldn't be shown</strong><p>Nothing was charged. Try again, or choose Finish later and come back.</p><button type="button" className="ba-btn sm" onClick={retry}>Try again</button></div>
      </div>
    )}>
      <Checkout {...props} />
    </ErrorBoundary>
  );
}

const reducedMotion = () => typeof window !== "undefined" && window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;

function Checkout({ summary, payment, start, confirm, onPayment, mount = mountEmbeddedCheckout, returned = false, payLabel = "Pay securely" }) {
  const [m, dispatch] = useReducer(reduce, payment, (p) => (returned && fromServer(p).state !== "confirmed" ? { state: "confirming", attempt: 0 } : fromServer(p)));
  const secret = useRef(null);      // { client_secret, publishable_key, livemode }: memory only, dropped once mounted
  const formEl = useRef(null);
  const handle = useRef(null);
  const cardRef = useRef(null), stageCardRef = useRef(null), sectionRef = useRef(null), headingRef = useRef(null);
  const first = useRef(true);
  const live = useRef(true);        // false only once this component leaves the page
  const [card, setCard] = useState(null);
  useEffect(() => { live.current = true; return () => { live.current = false; }; }, []);

  // the server's word moves the machine (it is the only source of "confirmed")
  useEffect(() => { dispatch({ type: "SERVER", payment }); }, [payment]);

  async function pay() {
    if (m.state !== "idle" && m.state !== "error") return;
    dispatch({ type: "PAY" });
    try {
      const r = await start();
      if (r?.status === "processing") return dispatch({ type: "PROCESSING" });
      if (r?.status !== "open" || typeof r.client_secret !== "string") throw Object.assign(new Error("no checkout"), { code: "CHECKOUT_NOT_READY" });
      secret.current = { clientSecret: r.client_secret, publishableKey: r.publishable_key, livemode: r.livemode };
      dispatch({ type: "SECRET" });
    } catch (err) {
      const kind = failureKind(err);
      dispatch(kind === "already_paid" ? { type: "ALREADY_PAID" } : { type: "FAIL", kind });
    }
  }

  // Stripe's form: mounted once per "loading", destroyed when the flow moves on or the page leaves
  useEffect(() => {
    if (m.state !== "loading" || !secret.current || !formEl.current) return undefined;
    // onComplete stays wired for as long as the form is on the page (the state moves to "ready" right after mounting)
    const opts = { ...secret.current, onComplete: () => { if (live.current) dispatch({ type: "COMPLETE" }); } };
    secret.current = null;
    mount(formEl.current, opts).then(
      (h) => { if (live.current) { handle.current = h; dispatch({ type: "MOUNTED" }); } else h?.destroy?.(); },
      (err) => { if (live.current) dispatch({ type: "FAIL", kind: failureKind(err) === "misconfigured" ? "misconfigured" : "stripe_load" }); },
    );
    return undefined;
  }, [m.state]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => {
    if (m.state !== "loading" && m.state !== "ready" && handle.current) { handle.current.destroy?.(); handle.current = null; }
  }, [m.state]);
  useEffect(() => () => { handle.current?.destroy?.(); handle.current = null; secret.current = null; }, []);

  // confirming: look again with backoff, then calmly once a minute; only the server's answer can confirm
  useEffect(() => {
    const wait = nextDelay(m);
    if (wait == null) return undefined;
    let alive = true;
    const t = setTimeout(async () => {
      if (m.state === "pending" && document.visibilityState !== "visible") return dispatch({ type: "STILL_WAITING" });
      try {
        const r = await confirm();
        if (!alive) return;
        if (r?.card) setCard(r.card);
        onPayment?.(r?.payment, r?.card ?? null);
        if (fromServer(r?.payment).state === "confirmed") dispatch({ type: "SERVER", payment: r.payment, card: r.card ?? null });
        else dispatch({ type: "STILL_WAITING" });
      } catch (err) { if (alive) dispatch({ type: "FAIL", kind: failureKind(err) }); }
    }, wait);
    return () => { alive = false; clearTimeout(t); };
  }, [m]); // eslint-disable-line react-hooks/exhaustive-deps

  // the card moves from its place in the panel to the centre (transform only), unless motion is reduced
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
    to.classList.add("zgc-fly");
  }, [staged]);

  // one heading takes focus when the state changes (not on first view), so keyboard and screen reader users follow
  useEffect(() => {
    if (first.current) { first.current = false; return; }
    if (m.state === "ready") return;   // the next Tab goes into Stripe's form; don't pull focus away from it
    headingRef.current?.focus({ preventScroll: false });
  }, [m.state, m.kind]);

  const words = m.state === "error" ? ERROR_WORDS[m.kind] ?? ERROR_WORDS.server : WORDS[m.state] ?? WORDS.off;
  const shownCard = m.state === "confirmed" ? cardWords(m.card ?? card) : null;
  // the server's amount (it sends it in every state); without one, no total is shown rather than a guess
  const amountKnown = summary?.amountMinor !== null && summary?.amountMinor !== undefined && summary?.amountMinor !== "" && Number.isFinite(Number(summary?.amountMinor));
  const amount = formatMoney(summary?.amountMinor, summary?.currency);
  const totalLabel = m.state === "off" || m.state === "locked" ? "Due when payment opens" : summary?.totalLabel ?? "Due today";
  const tone = m.state === "confirmed" ? "good" : m.state === "error" ? "urgent" : m.state === "pending" ? "heads" : "info";

  return (
    <section ref={sectionRef} className={`zgc is-${m.state}`} aria-labelledby="zgc-status">
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
          <div className="zgc-panel zgc-pay">
            <div className="zgc-pay-head">
              <span className="zob-kicker">Payment</span>
              <span className="zgc-secure"><Icon name="lock" size="sm" /> Secured by Stripe</span>
            </div>
            <CardArt ref={cardRef} confirmed={false} card={null} />
            <div className="zgc-form">
              {(m.state === "idle" || m.state === "submitting") && (
                <>
                  <p className="zob-muted">{summary?.intro ?? <>You'll pay <strong>{amount}</strong> today.</>} When you continue, Stripe's secure form opens right here.</p>
                  <button type="button" className="ba-btn primary zgc-pay-btn" disabled={m.state === "submitting"} onClick={pay}>
                    {m.state === "submitting" ? "Opening the secure form…" : payLabel}
                  </button>
                </>
              )}
              {m.state === "error" && (
                <button type="button" className="ba-btn primary zgc-pay-btn" onClick={() => { dispatch({ type: "RETRY" }); }}>{words.action ?? "Try again"}</button>
              )}
              {(m.state === "off" || m.state === "locked") && <p className="zob-muted">{m.state === "off" ? "Nothing is charged until payment opens here." : "Payment opens once your identity is verified."}</p>}
              {/* Stripe's iframe goes in here and sizes itself; the skeleton holds the space while it loads */}
              <div className={`zgc-embed${m.state === "loading" ? " is-loading" : ""}`} hidden={m.state !== "loading" && m.state !== "ready"}>
                {m.state === "loading" && <div className="zgc-skeleton" aria-hidden="true"><span /><span /><span /><span className="wide" /></div>}
                <div ref={formEl} className="zgc-embed-mount" />
              </div>
            </div>
          </div>

          <aside className="zgc-panel zgc-summary" aria-labelledby="zgc-summary-title">
            <span className="zob-kicker">{summary?.kicker ?? "Order summary"}</span>
            <h3 id="zgc-summary-title">{summary?.title ?? "Your plan"}</h3>
            <dl className="zgc-lines">
              {(summary?.lines ?? []).map(([label, value]) => <div key={label}><dt>{label}</dt><dd>{value}</dd></div>)}
            </dl>
            {amountKnown && <div className="zgc-total"><span>{totalLabel}</span><strong>{amount}</strong></div>}
            {summary?.footnote && <p className="zob-hint">{summary.footnote}</p>}
          </aside>
        </div>

        {staged && (
          <div className="zgc-stage" aria-hidden="true">
            <CardArt ref={stageCardRef} confirmed={m.state === "confirmed"} card={shownCard} big />
            <p className="zgc-stage-caption">{m.state === "confirmed" ? "Payment received" : m.state === "pending" ? "Still confirming" : "Confirming your payment"}</p>
          </div>
        )}
      </div>
    </section>
  );
}

// A generic card: no digits, ever, before a verified payment; afterwards only the brand and last 4 Stripe returned.
// Its colours are the look's own: primary for the card, the success token once confirmed.
function CardArtInner({ confirmed, card, big }, ref) {
  return (
    <div ref={ref} className={`zgc-card${big ? " big" : ""}${confirmed ? " ok" : ""}`} aria-hidden="true">
      <div className="zgc-card-face zgc-card-base">
        <span className="zgc-card-chip" />
        <span className="zgc-card-label">Your card</span>
        <span className="zgc-card-bars"><i /><i /><i /><i /></span>
      </div>
      <div className="zgc-card-face zgc-card-done">
        <span className="zgc-card-chip" />
        <span className="zgc-card-check"><Icon name="check_circle" /></span>
        <span className="zgc-card-label">{card ? `${card.brand} ending ${card.last4}` : "Paid"}</span>
      </div>
    </div>
  );
}
const CardArt = forwardRef(CardArtInner);
