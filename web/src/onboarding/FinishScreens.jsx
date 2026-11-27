import { useEffect, useRef, useState } from "react";
import { Icon } from "../BusinessUI";
import GlassCheckout from "../billing/GlassCheckout";
import { Actions, EmptyNote, ErrorText, useAction } from "./kit";
import { allowance, billingPeriod, errorCode, languageWords, money, paymentPassed, paymentState, tierName } from "./steps";

// Screens 5 to 7: Your plan, Pay, and You're all set.

// Your plan: exactly what the Zella Voice team saved for this business (contract §5.2 plan.current). The owner accepts
// it; there is no switching (rule plan_choice "accept_only"). Accepting also finishes the step (§5.5).
export function PlanScreen({ api, state, onState, onReload, onComplete }) {
  const plan = state.plan ?? {};
  const p = plan.current;
  const action = useAction();
  if (!plan.available || !p) return <EmptyNote title="Your plan isn't ready yet">The Zella Voice team is still preparing your plan and will be in touch. Choose Finish later and we'll pick up here.</EmptyNote>;
  const rows = [
    ["Call minutes", allowance(p.minutes, "minute"), "a month"],
    ["Texts", allowance(p.texts, "text"), "a month"],
    ["Emails", allowance(p.emails, "email"), "a month"],
    ["Team members", allowance(p.team_seats, "person", "people"), "can sign in"],
    ["Phone numbers", allowance(p.phone_numbers, "number"), ""],
    ["Locations", allowance(p.locations, "location"), ""],
    ["Languages", languageWords(p.languages), ""],
  ];
  const yearly = billingPeriod(p.billing_interval) === "a year";
  async function accept() {
    const ok = await action.run(async () => {
      if (plan.accepted && plan.accepted_version === p.version) return onComplete("plan");
      const res = await api.acceptPlan(state.business_id, p.version);
      onState(res.state, { advance: true });
    });
    // the plan changed while it was on screen: show the new one, with the reason above it
    if (!ok && errorCode(action.lastError) === "PLAN_CHANGED") onReload();
  }
  return (
    <>
      <p className="zob-lead">This is the plan the Zella Voice team set up for your business. If something looks wrong, don't accept it yet: choose Finish later and contact the Zella Voice team.</p>
      <section className="zob-card zob-plan" aria-labelledby="zob-plan-name">
        <div className="zob-plan-head">
          <div>
            <span className="zob-kicker">Your plan</span>
            <h2 id="zob-plan-name">{tierName(p.tier)}</h2>
          </div>
          <div className="zob-price">
            <strong>{money(p.price_cents, p.currency)}</strong>
            <span>{billingPeriod(p.billing_interval)}</span>
          </div>
        </div>
        <p className="zob-billed">Billed {yearly ? "yearly" : "monthly"}. You pay on the next step; nothing is charged before then.</p>
        {Number(p.setup_fee_cents) > 0 && <p className="zob-muted">Plus a one time setup fee of {money(p.setup_fee_cents, p.currency)}.</p>}
        {p.trial_enabled === true && <p className="zob-muted">Your plan starts with a free trial.</p>}
        <dl className="zob-allowances" aria-label="What's included">
          {rows.map(([label, value, sub]) => <div key={label}><dt>{label}</dt><dd><span>{value}</span>{sub && <> <small>{sub}</small></>}</dd></div>)}
        </dl>
        {Number(p.overage_cents_per_minute) > 0 && <p className="zob-muted">Extra minutes beyond your plan cost {money(p.overage_cents_per_minute, p.currency)} each.</p>}
      </section>
      {plan.accepted && plan.accepted_version === p.version && <div className="zob-done-note" role="status"><Icon name="task_alt" /><span>You accepted this plan.</span></div>}
      {!plan.accepted && plan.accepted_version != null && <p className="zob-muted" role="status">Your plan was just updated. Please review it again.</p>}
      <ErrorText>{action.error}</ErrorText>
      <Actions>
        <button type="button" className="ba-btn primary" disabled={action.busy} onClick={accept}>
          {action.busy ? "Saving…" : plan.accepted && plan.accepted_version === p.version ? "Continue" : "Accept plan and continue"}
        </button>
      </Actions>
    </>
  );
}

// Pay (owner, 27 Nov 2026): the glass checkout (billing/GlassCheckout.jsx) with Stripe's Embedded Checkout inside the
// page. While payments aren't switched on, the step says payment opens here soon and can be passed (owner decision,
// 16 Nov 2026). Once they are, Pay securely asks billing-api for the checkout (one key per attempt; a double click,
// a second tab or a reload gets the same open checkout from the server) and Stripe's own form opens in place. When
// Stripe finishes, or sends the owner back from a redirect, the screen asks OUR server again with backoff and shows
// "Payment received" only when the server confirms a verified, bound payment: Stripe finishing proves nothing by itself.
const newKey = () => (globalThis.crypto?.randomUUID?.() ?? `${Date.now()}-${Math.random().toString(36).slice(2)}`).replace(/[^A-Za-z0-9_-]/g, "");
export function PaymentScreen({ api, state, onState, onComplete }) {
  const st = paymentState(state.payment);
  // one key per attempt: a double click reuses it, but after a failed or expired start the next try uses a new one
  const key = useRef(newKey());
  const [returned] = useState(() => new URLSearchParams(window.location.search).get("checkout"));
  const action = useAction();
  const pay = state.payment ?? {};
  const p = state.plan?.current ?? {};
  const trial = pay.checkout?.mode === "trial" || pay.due_now_minor === 0;
  // back from Stripe (a payment method that redirects): the session id never stays in the address bar
  useEffect(() => {
    if (!returned) return;
    const u = new URL(window.location.href);
    ["checkout", "session_id"].forEach((k) => u.searchParams.delete(k));
    window.history.replaceState(null, "", u.pathname + u.search);
  }, []); // eslint-disable-line react-hooks/exhaustive-deps
  async function start() {
    try { return await api.startCheckout(state.business_id, key.current); }
    catch (err) { key.current = newKey(); throw err; }
  }
  const confirm = () => api.checkoutReturn(state.business_id);
  const onPayment = (payment) => { if (payment && typeof payment === "object") onState((s) => ({ ...s, payment })); };
  const period = billingPeriod(p.billing_interval);
  const lines = [["Plan price", `${money(p.price_cents, p.currency)} ${period}`]];
  if (Number(p.setup_fee_cents) > 0) lines.push(["One time setup fee", money(p.setup_fee_cents, p.currency)]);
  if (p.trial_enabled === true) lines.push(["Free trial", trial ? "Starts today" : "Not included"]);
  if (p.minutes != null) lines.push(["Call minutes", `${allowance(p.minutes, "minute")} ${period}`]);
  const summary = {
    kicker: "Order summary",
    title: p.tier ? `Your ${tierName(p.tier)} plan` : "Your plan",
    lines,
    totalLabel: "Due today",
    amountMinor: pay.checkout?.amount_minor ?? pay.due_now_minor,
    currency: pay.checkout?.currency ?? p.currency ?? "USD",
    intro: trial ? "Add a card to start your free trial. Nothing is charged until the trial ends." : undefined,
    footnote: "Stripe processes this payment for Zella Voice. The amount comes from the plan you accepted.",
  };
  return (
    <>
      <GlassCheckout summary={summary} payment={state.payment} start={start} confirm={confirm} onPayment={onPayment}
        mount={api.mountCheckout} returned={returned === "return"} payLabel={trial ? "Add a card and start my trial" : "Pay securely"} />
      {st.key === "waiting" && state.payment?.required === false && <p className="zob-muted">You can continue now. We'll ask for payment here once it's switched on.</p>}
      {st.key !== "confirmed" && state.payment?.required !== false && <p className="zob-muted">Your receptionist starts answering calls only after payment, so you're never charged for something that isn't working yet. You can choose Finish later and come back to this page any time.</p>}
      <ErrorText>{action.error}</ErrorText>
      {(st.key === "confirmed" || paymentPassed(state.payment)) && (
        <Actions><button type="button" className="ba-btn primary" disabled={action.busy} onClick={() => action.run(() => onComplete("payment"))}>{action.busy ? "One moment…" : "Continue"}</button></Actions>
      )}
    </>
  );
}

// You're all set: what happens next, the go live checklist as the server reports it, and the way into the CRM.
export function DoneScreen({ state, onComplete }) {
  const action = useAction();
  const checks = Array.isArray(state.go_live?.checks) ? state.go_live.checks : [];
  async function open() {
    const ok = state.completed_at ? true : await action.run(() => onComplete("done", { stay: true }));
    if (ok) window.location.assign(`/app?business=${encodeURIComponent(state.business_id)}`);
  }
  return (
    <>
      <p className="zob-lead">Thank you. {state.business_name} is set up. Here's what happens next.</p>
      <ol className="zob-ahead zob-next">
        <li><span className="zob-ahead-n" aria-hidden="true"><Icon name="call" size="sm" /></span><div><strong>A test call</strong><span>We make a test call to your receptionist and check its answers before anything goes live.</span></div></li>
        <li><span className="zob-ahead-n" aria-hidden="true"><Icon name="rocket_launch" size="sm" /></span><div><strong>Going live</strong><span>{state.go_live?.live ? "Your receptionist is live and answering your calls." : "Once every check below passes, your receptionist starts answering your calls. You can follow it on the AI receptionist page in your CRM."}</span></div></li>
        <li><span className="zob-ahead-n" aria-hidden="true"><Icon name="dashboard" size="sm" /></span><div><strong>Your CRM</strong><span>Your customers, bookings, calls and messages will all land there.</span></div></li>
      </ol>
      {checks.length > 0 && (
        <section className="zob-card zob-section" aria-labelledby="zob-golive">
          <h2 id="zob-golive">Before going live</h2>
          <ul className="zob-checks">
            {checks.map((c) => (
              <li key={c.key} className={c.ok ? "ok" : ""}>
                <Icon name={c.ok ? "check_circle" : "schedule"} size="sm" />
                <span>{c.label}</span>
                <span className={`zob-chip tone-${c.ok ? "good" : "heads"}`}>{c.ok ? "Done" : "Not yet"}</span>
              </li>
            ))}
          </ul>
        </section>
      )}
      <ErrorText>{action.error}</ErrorText>
      <Actions><button type="button" className="ba-btn primary" disabled={action.busy} onClick={open}>{action.busy ? "Opening…" : "Open my CRM"}</button></Actions>
    </>
  );
}
