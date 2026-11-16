import { useCallback, useEffect, useRef, useState } from "react";
import "../BusinessApp.css";
import "./onboarding.css";
import { BusinessSignIn, MfaCodeCard } from "../BusinessAuth";
import { ErrorBoundary, Icon, loadBusinessFonts } from "../BusinessUI";
import { getApi } from "./api";
import ProgressSteps from "./ProgressSteps";
import { Failed, Loading, NotReady } from "./kit";
import { SCREENS, STEP_KEYS, canOpen, errorCode, isNotReady, previousStep, resumeStep } from "./steps";
import { SecurityScreen, WelcomeScreen } from "./StartScreens";
import { DetailsScreen } from "./DetailsScreen";
import { IdentityScreen } from "./IdentityScreen";
import { DoneScreen, PaymentScreen, PlanScreen } from "./FinishScreens";

// The owner onboarding journey (/welcome/setup): what a business owner sees after opening their invitation, from
// Welcome to You're all set (docs/OWNER_ONBOARDING_CONTRACT.md). The server saves progress after every step and decides
// which step comes next; this page shows it. Finish later and coming back (from the email, or by signing in) lands on
// the same step. A call that isn't deployed yet shows "This step isn't ready yet", never a crash.

loadBusinessFonts();

const TITLES = {
  welcome: (s) => `Welcome to Zella Voice, ${s.business_name}`,
  security: () => "Password and two step sign in",
  details: () => "Check your details",
  identity: () => "Verify your identity",
  plan: () => "Your plan",
  payment: () => "Pay for your plan",
  done: () => "You're all set",
};
// Back only goes between these screens (never back into setting a password)
const CAN_GO_BACK = new Set(["identity", "plan", "payment"]);

export default function OwnerOnboarding() {
  const [api, setApi] = useState(null);
  const [session, setSession] = useState(undefined);
  useEffect(() => {
    let active = true;
    let stop = () => {};
    getApi().then(async (a) => {
      if (!active) return;
      setApi(a);
      stop = a.onAuthChange((next) => active && setSession(next));
      const s = await a.getSession().catch(() => null);
      if (active) setSession(s);
    });
    return () => { active = false; stop(); };
  }, []);

  if (!api || session === undefined) return <Frame><Loading text="One moment…" /></Frame>;
  if (!session) return <BusinessSignIn />;
  return <Gate api={api} session={session} />;
}

// A person who already has an authenticator enters its code first, as everywhere else in the CRM.
function Gate({ api, session }) {
  const [mfa, setMfa] = useState({ status: "checking" });
  const check = useCallback(async () => {
    try { const s = await api.mfaStatus(); setMfa({ status: "ok", needsCode: s.enrolled && s.level !== "aal2" }); }
    catch (error) { setMfa({ status: "error", error }); }
  }, [api]);
  useEffect(() => { check(); }, [check]);
  if (mfa.status === "checking") return <Frame><Loading text="Checking your sign in…" /></Frame>;
  if (mfa.status === "error") return <Frame title="Your setup"><Failed error={mfa.error} onRetry={() => { setMfa({ status: "checking" }); check(); }} /></Frame>;
  if (mfa.needsCode) return <MfaCodeCard email={session.user?.email} onDone={check} />;
  return <Journey api={api} email={session.user?.email ?? ""} />;
}

// Which business: the one named in the address (from the welcome link), if this owner has it waiting; else the
// first one waiting; else the first one. The server decides what "yours" means; this only picks from its list.
function pickBusiness(list) {
  const wanted = new URLSearchParams(window.location.search).get("business");
  return list.find((b) => b.business_id === wanted) ?? list.find((b) => b.completed === false) ?? list[0] ?? null;
}

function Journey({ api, email }) {
  const [load, setLoad] = useState({ status: "loading" });
  const [state, setState] = useState(null);
  const [view, setView] = useState(null);
  const [left, setLeft] = useState(null);       // after Finish later: { saved }
  const [leaving, setLeaving] = useState(false);
  const heading = useRef(null);

  const start = useCallback(async () => {
    setLoad({ status: "loading" });
    try {
      // the owner's membership becomes active before the first call (contract §1); its own problems never block here
      await api.acceptInvitations().catch(() => null);
      const list = await api.listBusinesses();
      const chosen = pickBusiness(Array.isArray(list?.businesses) ? list.businesses : []);
      if (!chosen) { setLoad({ status: "none" }); return; }
      let next = await api.getState(chosen.business_id);
      // coming back after Finish later: tell the server (admins see "came back on ..."); never blocks the owner
      if (next?.paused_at) next = (await api.resume(chosen.business_id).catch(() => null))?.state ?? next;
      setState(next);
      setView(resumeStep(next));
      setLoad({ status: "ready" });
    } catch (error) {
      setLoad({ status: isNotReady(error) ? "notready" : "error", error });
    }
  }, [api]);
  useEffect(() => { start(); }, [start]);

  // each new step: its heading takes focus, so keyboard and screen reader users start at the top of it
  useEffect(() => { if (view) heading.current?.focus(); }, [view, left]);

  const show = useCallback((step) => { setView(step); window.scrollTo?.(0, 0); }, []);
  // Every answer from the server carries the whole state; the screens hand it back here.
  const onState = useCallback((next, { advance = false } = {}) => {
    if (!next) return;
    setState(next);
    if (advance) show(resumeStep(next));
  }, [show]);
  const reload = useCallback(async () => {
    if (!state) return;
    try { setState(await api.getState(state.business_id)); } catch { /* the screen keeps what it has, and says why it failed */ }
  }, [api, state]);
  // Finishes a step on the server, then shows the step it says comes next. Errors go back to the screen.
  const onComplete = useCallback(async (step, { stay = false } = {}) => {
    try {
      const res = await api.completeStep(state.business_id, step);
      onState(res?.state, { advance: !stay });
    } catch (error) {
      // a step that is already further along, or an earlier one reopened: show where the server says we are
      if (["STEP_LOCKED", "SECURITY_INCOMPLETE", "SECTIONS_NOT_CONFIRMED"].includes(errorCode(error))) reload();
      throw error;
    }
  }, [api, state, onState, reload]);

  async function finishLater() {
    setLeaving(true);
    let saved = true;
    try { await api.finishLater(state.business_id); } catch { saved = false; }
    setLeaving(false);
    setLeft({ saved });
  }

  if (load.status === "loading") return <Frame><Loading text="Loading your setup…" /></Frame>;
  if (load.status === "notready") return <Frame title="Your setup"><NotReady onRetry={start}>Your setup screens aren't switched on yet. You can open your CRM now and come back here later to finish setting up.</NotReady><OpenCrm /></Frame>;
  if (load.status === "none") return <Frame title="Nothing to set up here"><p className="zob-lead">This setup is for the owner of a new Zella Voice business, and your account has nothing waiting. If you were invited as an owner, open the newest invitation email again.</p><OpenCrm /></Frame>;
  if (load.status === "error") {
    if (errorCode(load.error) === "NOT_ALLOWED") return <Frame title="Only the business owner can do this"><p className="zob-lead">This setup is for the owner of the business. You can still use your CRM as usual.</p><OpenCrm /></Frame>;
    return <Frame title="Your setup"><Failed error={load.error} onRetry={start} /></Frame>;
  }

  if (state.business_available === false) {
    return <Frame state={state} title="This workspace is paused"><p className="zob-lead">Please contact Zella Voice support to carry on setting up {state.business_name}.</p></Frame>;
  }

  const step = STEP_KEYS.includes(view) ? view : resumeStep(state);
  const back = CAN_GO_BACK.has(step) ? previousStep(step) : null;
  const props = { api, state, email, onState, onComplete, onReload: reload, onRefresh: reload };

  if (left) {
    const at = SCREENS.find((s) => s.key === resumeStep(state))?.label ?? "the same step";
    return (
      <Frame state={state}>
        <h1 ref={heading} tabIndex={-1}>{left.saved ? "Your place is saved" : "You can come back any time"}</h1>
        <p className="zob-lead">{left.saved
          ? `Next time, you'll start right here, at ${at.toLowerCase()}. Sign in to Zella Voice at any time and choose Finish setting up.`
          : "We couldn't record that you're leaving, but everything you finished is saved. You'll pick up from the first step that isn't done."}</p>
        <div className="zob-actions">
          <button type="button" className="ba-btn primary" onClick={() => { setLeft(null); api.resume(state.business_id).catch(() => {}); }}>Carry on now</button>
          <button type="button" className="ba-btn" onClick={() => api.signOut()}>Sign out</button>
        </div>
      </Frame>
    );
  }

  return (
    <Frame state={state} onFinishLater={step === "done" ? null : finishLater} leaving={leaving}>
      <ProgressSteps screens={SCREENS} current={STEP_KEYS.indexOf(step)} />
      {back && canOpen(state, back) && <button type="button" className="ba-link zob-back" onClick={() => show(back)}><Icon name="arrow_back" size="sm" /> Back</button>}
      <h1 ref={heading} tabIndex={-1}>{TITLES[step](state)}</h1>
      {step !== resumeStep(state) && canOpen(state, step) && step !== "done" && (
        <p className="zob-muted zob-lookback">You finished this step. <button type="button" className="ba-link" onClick={() => show(resumeStep(state))}>Go to where you left off</button></p>
      )}
      <ErrorBoundary resetKey={step} fallback={(retry) => (
        <div className="zob-state zob-state-box error" role="alert">
          <Icon name="error" />
          <div><strong>This step couldn't be shown</strong><p>Nothing you saved was lost.</p><button type="button" className="ba-btn sm" onClick={retry}>Try again</button></div>
        </div>
      )}>
        {step === "welcome" && <WelcomeScreen {...props} />}
        {step === "security" && <SecurityScreen {...props} />}
        {step === "details" && <DetailsScreen {...props} />}
        {step === "identity" && <IdentityScreen {...props} />}
        {step === "plan" && <PlanScreen {...props} />}
        {step === "payment" && <PaymentScreen {...props} />}
        {step === "done" && <DoneScreen {...props} />}
      </ErrorBoundary>
    </Frame>
  );
}

function OpenCrm() {
  return <div className="zob-actions"><a className="ba-btn primary" href="/app">Open my CRM</a></div>;
}

// The page: the Zella Voice name, the business, Finish later, and one column of content (wider on a desktop).
function Frame({ state, title, onFinishLater, leaving, children }) {
  const titleRef = useRef(null);
  useEffect(() => { if (title) titleRef.current?.focus(); }, [title]);
  return (
    <div className="ba-root zob">
      <header className="zob-top">
        <div className="zob-brand">
          <div className="ba-logo" aria-hidden="true">Z</div>
          <div>
            <div className="ba-brand-name">Zella Voice</div>
            {state?.business_name && <div className="ba-brand-sub">{state.business_name}</div>}
          </div>
        </div>
        {onFinishLater && <button type="button" className="ba-btn sm" disabled={leaving} onClick={onFinishLater}>{leaving ? "Saving…" : "Finish later"}</button>}
      </header>
      <main className="zob-main">
        <div className="zob-card zob-page">
          {title && <h1 ref={titleRef} tabIndex={-1}>{title}</h1>}
          {children}
        </div>
      </main>
    </div>
  );
}
