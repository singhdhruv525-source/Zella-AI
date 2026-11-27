import { forwardRef, useEffect, useLayoutEffect, useReducer, useRef, useState } from "react";
import { ErrorBoundary, Icon } from "../BusinessUI";
import { cardWords, ERROR_WORDS, failureKind, formatMoney, fromServer, nextDelay, reduce, WORDS } from "./checkoutMachine";
import { mountEmbeddedCheckout } from "./stripeEmbedded";
import "./glassCheckout.css";

// The glass checkout (owner, 27 Nov 2026): three panels like a real checkout: the customer's card on the left, a
// "Payment details" panel in the middle that holds Stripe's own form, and the order summary as a receipt on the right
// (the card above the payment panel on a tablet; one column on a phone). Every payment the owner makes uses it: the
// onboarding Pay step (Stripe Embedded Checkout), Pay now for an unpaid invoice and finishing a pack (Stripe's Payment
// Element), and buying a pack on the saved card (no form, our Pay button). After Stripe finishes, the panels blur behind
// a frosted layer, the card lifts to the centre while we confirm with OUR server, and flips to the look's success colour
// only when the server confirms. Tokens only, so every Zella Voice look follows.
//
// Card data never touches this code (NN-9): the card is typed only into Stripe's frame, which this page can't read. The
// card picture never mirrors anything typed: before payment it shows dots and "Your card"; after a confirmed payment
// only the brand, last 4 and issuing bank the server returned from Stripe. It never shows the Zella Voice name: it is
// the customer's card, not ours.
//
// Props:
//   summary      { kicker, title, lines: [[label, value, icon]], totalLabel, amountMinor, currency, footnote, intro }
//   payment      the server's state in the onboarding payment shape ({ status, reason, checkout_available })
//   start()      asks our server: { status: "open", client_secret, publishable_key, livemode } or { status: "processing" }
//   actStart()   the same, for "Confirm with your bank" or "Pay with another card" on a pack (its own PaymentIntent)
//   confirm()    asks our server again: { payment, card?, stopped? }. The only way to "Payment received".
//   mount        (el, opts) => Promise<{ destroy, submit? }>; submit() means our Pay button confirms the form
//   onUpdateCard opens Stripe's card update (for "There's no card to charge")
//   words        per state overrides, e.g. { confirmed: { label, body } } for an invoice already paid
//   payLabel     the first button's words; submitLabel the Pay button under Stripe's Payment Element
export default function GlassCheckout(props) {
  return (
    <ErrorBoundary resetKey="glass-checkout" fallback={(retry) => (
      <div className="zob-state zob-state-box error" role="alert">
        <Icon name="error" />
        <div><strong>The payment form couldn't be shown</strong><p>Nothing was charged. Try again, or come back later.</p><button type="button" className="ba-btn sm" onClick={retry}>Try again</button></div>
      </div>
    )}>
      <Checkout {...props} />
    </ErrorBoundary>
  );
}

const reducedMotion = () => typeof window !== "undefined" && window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
const finePointer = () => typeof window !== "undefined" && window.matchMedia?.("(hover: hover) and (pointer: fine)").matches;

function Checkout({ summary, payment, start, actStart, confirm, onPayment, mount = mountEmbeddedCheckout, returned = false, payLabel = "Pay securely",
  submitLabel, words: over = {}, onUpdateCard, detailsNote }) {
  const [m, dispatch] = useReducer(reduce, payment, (p) => (returned && fromServer(p).state !== "confirmed" ? { state: "confirming", attempt: 0 } : fromServer(p)));
  const secret = useRef(null);      // { clientSecret, publishableKey, livemode }: memory only, dropped once mounted
  const formEl = useRef(null);
  const handle = useRef(null);
  const cardRef = useRef(null), stageCardRef = useRef(null), headingRef = useRef(null);
  const first = useRef(true);
  const live = useRef(true);        // false only once this component leaves the page
  const [card, setCard] = useState(null);
  const [canSubmit, setCanSubmit] = useState(false);
  const [sending, setSending] = useState(false);
  const [inline, setInline] = useState("");   // Stripe's own words for a declined card, under its form
  useEffect(() => { live.current = true; return () => { live.current = false; }; }, []);

  // the server's word moves the machine (it is the only source of "confirmed")
  useEffect(() => { dispatch({ type: "SERVER", payment }); }, [payment]);

  async function begin(which) {
    if (m.state !== "idle" && m.state !== "error") return;
    dispatch({ type: "PAY" });
    setInline("");
    try {
      const r = await (which === "act" ? actStart : start)();
      if (r?.status === "processing") return dispatch({ type: "PROCESSING" });
      if (r?.status !== "open" || typeof r.client_secret !== "string") throw Object.assign(new Error("no checkout"), { code: "CHECKOUT_NOT_READY" });
      secret.current = { clientSecret: r.client_secret, publishableKey: r.publishable_key, livemode: r.livemode };
      dispatch({ type: "SECRET" });
    } catch (err) {
      const kind = failureKind(err);
      dispatch(kind === "already_paid" ? { type: "ALREADY_PAID" } : { type: "FAIL", kind, words: kind === "refused" ? err?.words ?? err?.message : undefined });
    }
  }
  function errorAction() {
    if (m.kind === "needs_action" || m.kind === "card_declined") return begin("act");
    if (m.kind === "no_card") return onUpdateCard?.();
    dispatch({ type: "RETRY" });
  }
  async function submit() {
    if (!handle.current?.submit || sending) return;
    setSending(true); setInline("");
    try { await handle.current.submit(); }
    catch (err) { if (live.current) setInline(err?.code === "DECLINED" ? err.message : "The payment didn't go through. Nothing was charged. Please try again."); }
    finally { if (live.current) setSending(false); }
  }

  // Stripe's form: mounted once per "loading", destroyed when the flow moves on or the page leaves
  useEffect(() => {
    if (m.state !== "loading" || !secret.current || !formEl.current) return undefined;
    // onComplete stays wired for as long as the form is on the page (the state moves to "ready" right after mounting)
    const opts = { ...secret.current, amountLabel: formatMoney(summary?.amountMinor, summary?.currency), returnUrl: window.location.href,
      onComplete: () => { if (live.current) dispatch({ type: "COMPLETE" }); } };
    secret.current = null;
    mount(formEl.current, opts).then(
      (h) => { if (live.current) { handle.current = h; setCanSubmit(typeof h?.submit === "function"); dispatch({ type: "MOUNTED" }); } else h?.destroy?.(); },
      (err) => { if (live.current) dispatch({ type: "FAIL", kind: failureKind(err) === "misconfigured" ? "misconfigured" : "stripe_load" }); },
    );
    return undefined;
  }, [m.state]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => {
    if (m.state !== "loading" && m.state !== "ready" && handle.current) { handle.current.destroy?.(); handle.current = null; setCanSubmit(false); }
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
        if (r?.stopped) dispatch({ type: "STOPPED", kind: r.stopped });
        else if (fromServer(r?.payment).state === "confirmed") dispatch({ type: "SERVER", payment: r.payment, card: r.card ?? null });
        else dispatch({ type: "STILL_WAITING" });
      } catch (err) { if (alive) dispatch({ type: "FAIL", kind: failureKind(err) }); }
    }, wait);
    return () => { alive = false; clearTimeout(t); };
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
    if (m.state === "ready") return;   // the next Tab goes into Stripe's form; don't pull focus away from it
    headingRef.current?.focus({ preventScroll: false });
  }, [m.state, m.kind]);

  const base = m.state === "error" ? ERROR_WORDS[m.kind] ?? ERROR_WORDS.server : WORDS[m.state] ?? WORDS.off;
  const words = { ...base, ...(over[m.state === "error" ? m.kind : m.state] ?? {}), ...(m.state === "error" && m.kind === "refused" && m.words ? { body: `${m.words} Nothing was charged.` } : {}) };
  const shownCard = m.state === "confirmed" ? cardWords(m.card ?? card) : null;
  // the server's amount (it sends it in every state); without one, no total is shown rather than a guess
  const amountKnown = summary?.amountMinor !== null && summary?.amountMinor !== undefined && summary?.amountMinor !== "" && Number.isFinite(Number(summary?.amountMinor));
  const amount = formatMoney(summary?.amountMinor, summary?.currency);
  const totalLabel = m.state === "off" || m.state === "locked" ? "Due when payment opens" : summary?.totalLabel ?? "Due today";
  const tone = m.state === "confirmed" ? "good" : m.state === "error" ? "urgent" : m.state === "pending" ? "heads" : "info";

  return (
    <section className={`zgc is-${m.state}`} aria-labelledby="zgc-status">
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
            <CardArt ref={cardRef} confirmed={false} card={null} tilt />
            <p className="zgc-cardcol-note"><Icon name="visibility_off" size="sm" /> This picture never shows your card number.</p>
          </div>

          <div className="zgc-panel zgc-pay" aria-labelledby="zgc-pay-title">
            <div className="zgc-pay-head">
              <h3 id="zgc-pay-title">Payment details</h3>
            </div>
            <div className="zgc-form">
              {(m.state === "idle" || m.state === "submitting") && (
                <p className="zob-muted">{summary?.intro ?? <>You'll pay <strong>{amount}</strong> today. When you continue, Stripe's secure form opens right here.</>}</p>
              )}
              {detailsNote && (m.state === "idle" || m.state === "submitting") && <p className="zgc-details-note">{detailsNote}</p>}
              {(m.state === "off" || m.state === "locked") && <p className="zob-muted">{m.state === "off" ? "Nothing is charged until payment opens here." : "Payment opens once your identity is verified."}</p>}
              {/* Stripe's iframe goes in here and sizes itself; the skeleton holds the space while it loads */}
              <div className={`zgc-embed${m.state === "loading" ? " is-loading" : ""}`} hidden={m.state !== "loading" && m.state !== "ready"}>
                {m.state === "loading" && <div className="zgc-skeleton" aria-hidden="true"><span /><span /><span /><span className="wide" /></div>}
                <div ref={formEl} className="zgc-embed-mount" />
              </div>
              {m.state === "ready" && canSubmit && inline && <p className="ba-error" role="alert">{inline}</p>}
            </div>
            <div className="zgc-pay-foot">
              {(m.state === "idle" || m.state === "submitting") && (
                <button type="button" className="ba-btn primary zgc-pay-btn" disabled={m.state === "submitting"} onClick={() => begin("start")}>
                  <Icon name="lock" size="sm" /> {m.state === "submitting" ? "Opening the secure form…" : payLabel}
                </button>
              )}
              {m.state === "ready" && canSubmit && (
                <button type="button" className="ba-btn primary zgc-pay-btn" disabled={sending} onClick={submit}>
                  <Icon name="lock" size="sm" /> {sending ? "Paying…" : submitLabel ?? `Pay ${amount}`}
                </button>
              )}
              {m.state === "error" && words.action && (
                <button type="button" className="ba-btn primary zgc-pay-btn" onClick={errorAction}>{words.action}</button>
              )}
              {m.state === "error" && m.kind === "card_declined" && onUpdateCard && (
                <button type="button" className="ba-btn zgc-pay-btn" onClick={onUpdateCard}>Update saved card</button>
              )}
              <p className="zgc-trust">
                <span><Icon name="lock" size="sm" /> Secured by Stripe</span>
                <span><Icon name="verified_user" size="sm" /> Card details never reach Zella Voice</span>
              </p>
            </div>
          </div>

          <aside className="zgc-panel zgc-summary" aria-labelledby="zgc-summary-title">
            <span className="zob-kicker">{summary?.kicker ?? "Order summary"}</span>
            <h3 id="zgc-summary-title">{summary?.title ?? "Your plan"}</h3>
            <dl className="zgc-lines">
              {(summary?.lines ?? []).map(([label, value, icon]) => (
                <div key={label}>
                  <dt>{icon && <span className="zgc-line-icon" aria-hidden="true"><Icon name={icon} size="sm" /></span>}{label}</dt>
                  <dd>{value}</dd>
                </div>
              ))}
            </dl>
            {amountKnown && <div className="zgc-total"><span>{totalLabel}</span><strong>{amount}</strong></div>}
            {summary?.footnote && <p className="zob-hint">{summary.footnote}</p>}
          </aside>
        </div>

        {staged && (
          <div className="zgc-stage" aria-hidden="true">
            <div className="zgc-stage-card">
              <span className="zgc-floor" />
              <span className="zgc-glow" />
              <CardArt ref={stageCardRef} confirmed={m.state === "confirmed"} card={shownCard} big />
            </div>
            {m.state !== "confirmed" && (
              <svg className="zgc-ring" viewBox="0 0 40 40" width="40" height="40"><circle className="zgc-ring-track" cx="20" cy="20" r="16" /><circle className="zgc-ring-arc" cx="20" cy="20" r="16" /></svg>
            )}
            <p className="zgc-stage-caption">{m.state === "confirmed" ? words.label : m.state === "pending" ? "Still confirming" : "Confirming your payment"}</p>
          </div>
        )}
      </div>
    </section>
  );
}

// ---------- the card picture ----------
// A metallic EMV chip: tokens --zella-metal-1..3 for the gradient, darker contact pads and an engraved outline.
let chipSeq = 0;
function Chip() {
  const [gid] = useState(() => `zgc-chip-${++chipSeq}`);
  return (
    <svg className="zgc-chip" viewBox="0 0 50 38" width="50" height="38">
      <defs>
        <linearGradient id={`${gid}-m`} x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" className="zgc-metal-1" /><stop offset="0.45" className="zgc-metal-2" /><stop offset="0.7" className="zgc-metal-1" /><stop offset="1" className="zgc-metal-3" />
        </linearGradient>
      </defs>
      <rect x="0.75" y="0.75" width="48.5" height="36.5" rx="6.5" fill={`url(#${gid}-m)`} className="zgc-chip-edge" />
      <path className="zgc-chip-pads" d="M0.75 12.5h15.5M0.75 25.5h15.5M33.75 12.5h15.5M33.75 25.5h15.5M16.25 0.75v36.5M33.75 0.75v36.5M16.25 19h17.5M21 12.5h8a4 4 0 0 1 4 4v5a4 4 0 0 1-4 4h-8a4 4 0 0 1-4-4v-5a4 4 0 0 1 4-4z" />
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
// pointer tilt with a specular highlight that follows it (fine pointers only; never with reduced motion)
function useTilt(enabled) {
  const ref = useRef(null);
  useEffect(() => {
    const el = ref.current;
    if (!enabled || !el || reducedMotion() || !finePointer()) return undefined;
    const move = (e) => {
      if (e.pointerType && e.pointerType !== "mouse") return;
      const r = el.getBoundingClientRect(), x = (e.clientX - r.left) / r.width, y = (e.clientY - r.top) / r.height;
      el.style.setProperty("--zgc-rx", `${((0.5 - y) * 10).toFixed(2)}deg`);
      el.style.setProperty("--zgc-ry", `${((x - 0.5) * 14).toFixed(2)}deg`);
      el.style.setProperty("--zgc-sx", `${((x - 0.5) * 100).toFixed(1)}%`);
      el.style.setProperty("--zgc-sy", `${((y - 0.5) * 100).toFixed(1)}%`);
      el.classList.add("is-tilting");
    };
    const leave = () => { el.classList.remove("is-tilting"); ["--zgc-rx", "--zgc-ry", "--zgc-sx", "--zgc-sy"].forEach((k) => el.style.removeProperty(k)); };
    el.addEventListener("pointermove", move); el.addEventListener("pointerleave", leave);
    return () => { el.removeEventListener("pointermove", move); el.removeEventListener("pointerleave", leave); };
  }, [enabled]);
  return ref;
}
function CardArtInner({ confirmed, card, big, tilt }, ref) {
  const tiltRef = useTilt(tilt);
  return (
    <div ref={ref} className={`zgc-card${big ? " big" : ""}${confirmed ? " ok" : ""}${tilt ? " tilt" : ""}`} aria-hidden="true">
      <div ref={tiltRef} className="zgc-card-tiltbox">
        <div className="zgc-card-inner">
          <span className="zgc-card-edge" />
          <div className="zgc-card-face zgc-card-base">
            <div className="zgc-card-row"><span className="zgc-card-issuer" /><Contactless /></div>
            <div className="zgc-card-row zgc-card-mid"><Chip /></div>
            <div className="zgc-card-number">•••• •••• •••• ••••</div>
            <div className="zgc-card-row"><span className="zgc-card-label">Your card</span><span className="zgc-card-brand" /></div>
            <span className="zgc-card-spec" />
            <span className="zgc-card-shimmer" />
          </div>
          <div className="zgc-card-face zgc-card-done">
            {/* the issuing bank in the corner, only as the server passed on from Stripe (plain text, never a logo) */}
            <div className="zgc-card-row"><span className="zgc-card-issuer">{card?.issuer ?? ""}</span><Contactless /></div>
            <div className="zgc-card-row zgc-card-mid">
              <Chip />
              <svg className="zgc-check" viewBox="0 0 36 36" width="36" height="36"><circle cx="18" cy="18" r="16" /><path d="M11 18.5l5 5 9.5 -10.5" /></svg>
            </div>
            <div className="zgc-card-number">{card ? `ending ${card.last4}` : "Paid"}</div>
            <div className="zgc-card-row"><span className="zgc-card-label">Payment received</span><span className="zgc-card-brand">{card?.brand ?? ""}</span></div>
          </div>
        </div>
      </div>
    </div>
  );
}
const CardArt = forwardRef(CardArtInner);
