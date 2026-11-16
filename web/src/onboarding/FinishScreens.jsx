import { useEffect, useState } from "react";
import { Icon } from "../BusinessUI";
import { Actions, EmptyNote, ErrorText, useAction } from "./kit";
import { allowance, billingPeriod, errorCode, errorWords, languageWords, money, paymentState, tierName } from "./steps";

// Screens 5 to 7: Your plan, Pay, and You're all set.

// Your plan: exactly what the Zella Voice team saved for this business (contract §5.2 plan.current). The owner accepts
// it; there is no switching (rule plan_choice "accept_only"). Accepting also finishes the step (§5.5).
export function PlanScreen({ api, state, onState, onReload, onComplete }) {
  const plan = state.plan ?? {};
  const p = plan.current;
  const action = useAction();
  if (!plan.available || !p) return <EmptyNote title="Your plan isn't ready yet">The Zella Voice team is still preparing your plan and will be in touch. Choose Finish later and we'll pick up here.</EmptyNote>;
  const rows = [
    ["Call minutes", allowance(p.minutes, "minute"), "each month"],
    ["Texts", allowance(p.texts, "text"), "each month"],
    ["Emails", allowance(p.emails, "email"), "each month"],
    ["Team members", allowance(p.team_seats, "person", "people"), "who can sign in"],
    ["Phone numbers", allowance(p.phone_numbers, "number"), ""],
    ["Locations", allowance(p.locations, "location"), ""],
    ["Languages", languageWords(p.languages), "your receptionist speaks"],
  ];
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
      <p className="zob-lead">This is the plan the Zella Voice team set up for your business. If something looks wrong, choose Finish later and reply to your invitation email before you accept.</p>
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
        {Number(p.setup_fee_cents) > 0 && <p className="zob-muted">Plus a one time setup fee of {money(p.setup_fee_cents, p.currency)}.</p>}
        {p.trial_enabled === true && <p className="zob-muted">Your plan starts with a free trial.</p>}
        <h3 className="zob-subhead">What's included</h3>
        <dl className="zob-allowances">
          {rows.map(([label, value, sub]) => <div key={label}><dt>{label}</dt><dd>{value}{sub && <small> {sub}</small>}</dd></div>)}
        </dl>
        {Number(p.overage_cents_per_minute) > 0 && <p className="zob-muted">Extra minutes beyond your plan cost {money(p.overage_cents_per_minute, p.currency)} each.</p>}
      </section>
      {plan.accepted && plan.accepted_version === p.version && <div className="zob-done-note" role="status"><Icon name="task_alt" /><span>You accepted this plan.</span></div>}
      <ErrorText>{action.error}</ErrorText>
      <Actions>
        <button type="button" className="ba-btn primary" disabled={action.busy} onClick={accept}>
          {action.busy ? "Saving…" : plan.accepted && plan.accepted_version === p.version ? "Continue" : "Accept plan and continue"}
        </button>
      </Actions>
    </>
  );
}

// Pay. Payments aren't connected yet (rule payments_connected false), so the owner sees a calm waiting screen.
// "Payment received" shows only when the server says the payment is confirmed; nothing here pretends one happened.
export function PaymentScreen({ api, state, onState, onComplete }) {
  const st = paymentState(state.payment);
  const [checking, setChecking] = useState(false);
  const [problem, setProblem] = useState("");
  const action = useAction();
  async function refresh() {
    setChecking(true);
    try { onState({ ...state, payment: await api.paymentStatus(state.business_id) }); setProblem(""); }
    catch (err) { setProblem(errorWords(err)); }
    finally { setChecking(false); }
  }
  // while waiting, look again once a minute while the page is in view
  useEffect(() => {
    if (st.key === "confirmed") return undefined;
    const t = setInterval(() => { if (document.visibilityState === "visible") refresh(); }, 60000);
    return () => clearInterval(t);
  }, [st.key]); // eslint-disable-line react-hooks/exhaustive-deps
  return (
    <>
      <div className={`zob-status tone-${st.tone}`} role="status" aria-live="polite">
        <span className="ba-icon" aria-hidden="true">{{ confirmed: "paid", locked: "lock", waiting: "schedule" }[st.key]}</span>
        <div>
          <strong>{st.label}</strong>
          <p>{{
            confirmed: "Thank you. Your payment is confirmed.",
            locked: "You'll be able to pay once your identity is verified.",
            waiting: "You'll pay for your plan right here. We're finishing this part now. Nothing is charged until then.",
          }[st.key]}</p>
        </div>
      </div>
      {st.key !== "confirmed" && <p className="zob-muted">Your receptionist starts answering calls only after payment, so you're never charged for something that isn't working yet. You can choose Finish later and come back to this page any time.</p>}
      <ErrorText>{problem || action.error}</ErrorText>
      <Actions>
        {st.key === "confirmed"
          ? <button type="button" className="ba-btn primary" disabled={action.busy} onClick={() => action.run(() => onComplete("payment"))}>{action.busy ? "One moment…" : "Continue"}</button>
          : <button type="button" className="ba-btn" disabled={checking} onClick={refresh}>{checking ? "Checking…" : "Check again"}</button>}
      </Actions>
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
      <ol className="zob-ahead">
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
                <Icon name={c.ok ? "check_circle" : "radio_button_unchecked"} size="sm" />
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
