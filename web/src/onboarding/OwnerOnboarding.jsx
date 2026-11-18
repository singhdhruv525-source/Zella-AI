import { useCallback, useEffect, useRef, useState } from "react";
import "../BusinessApp.css";
import "./onboarding.css";
import { BusinessSignIn, MfaCodeCard } from "../BusinessAuth";
import { ErrorBoundary, Icon, loadBusinessFonts } from "../BusinessUI";
import { SidebarBrand } from "../navigation/SidebarBrand";
import { getApi } from "./api";
import ProgressSteps from "./ProgressSteps";
import { ErrorText, Failed, Loading, NotReady } from "./kit";
import { SCREENS, STEP_KEYS, afterCompleteError, canOpen, errorCode, isNotReady, previousStep, resumeStep, stateAfterResume, stepAfterError } from "./steps";
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
  // "You're all set" only once every go live check has passed; until then, say what is still to come
  done: (s) => (allChecksDone(s) ? "You're all set" : "Setup complete. One last check before you go live."),
};
function allChecksDone(s) {
  const checks = Array.isArray(s.go_live?.checks) ? s.go_live.checks : [];
  return s.go_live?.live === true || (checks.length > 0 && checks.every((c) => c.ok));
}
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
  // keyed by the person, so a different account signing in starts again (its own sign in check and setup)
  return <Gate key={session.user?.id ?? "signed-in"} api={api} session={session} />;
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
// A state answer must be there: a missing one is a failed load (the error view with Try again), never a blank screen.
function needState(state) {
  if (!state || typeof state !== "object") throw new Error("Your setup didn't load.");
  return state;
}

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
      // a missing list is a failed load (Try again), never "nothing to set up"
      if (!Array.isArray(list?.businesses)) throw new Error("The list of your businesses didn't load.");
      const chosen = pickBusiness(list.businesses);
      if (!chosen) { setLoad({ status: "none" }); return; }
      let next = needState(await api.getState(chosen.business_id));
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
  // A screen may pass a function of the latest state (used by the polls, so an answer never overwrites newer state).
  const onState = useCallback((next, { advance = false } = {}) => {
    if (!next) return;
    if (typeof next === "function") { setState((cur) => (cur ? next(cur) : cur)); return; }
    setState(next);
    if (advance) show(resumeStep(next));
  }, [show]);
  // Reads the state again. refresh lets a failure reach the screen (which says so); reload keeps what is shown.
  const refresh = useCallback(async () => { if (state) setState(needState(await api.getState(state.business_id))); }, [api, state]);
  const reload = useCallback(() => refresh().catch(() => {}), [refresh]);
  // Carry on now after Finish later: show the server's state, so a part saved just before leaving isn't asked for again.
  // If neither answers, the paused screen stays and says so, so nothing finished is asked for again.
  const carryOn = useCallback(async () => {
    setLeaving(true);
    const next = await stateAfterResume(api, state.business_id);
    setLeaving(false);
    if (!next) { setLeft((cur) => ({ ...cur, retry: true })); return; }
    setState(next); setView(resumeStep(next)); setLeft(null);
  }, [api, state]);
  // Finishes a step on the server, then shows the step it says comes next. Errors go back to the screen.
  const onComplete = useCallback(async (step, { stay = false } = {}) => {
    try {
      const res = await api.completeStep(state.business_id, step);
      onState(res?.state, { advance: !stay });
    } catch (error) {
      // A new plan version was saved while this step was open (show the plan, which says so), or the server is on another
      // step (show that one). The state is read again first; the error still goes back to the screen, so it never treats
      // the step as finished (the last step would open the CRM). If reading fails, the screen stays as it is.
      const next = afterCompleteError(step, error);
      if (next) {
        const fresh = await api.getState(state.business_id).catch(() => null);
        if (fresh) { setState(fresh); show(stepAfterError(next, fresh)); }
      }
      throw error;
    }
  }, [api, state, onState, show]);

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
    // the server wants this session verified with a code first (contract §4, version 2)
    if (errorCode(load.error) === "MFA_REQUIRED") return <MfaCodeCard email={email} onDone={start} />;
    if (errorCode(load.error) === "NOT_ALLOWED") return <Frame title="Only the business owner can do this"><p className="zob-lead">This setup is for the owner of the business. You can still use your CRM as usual.</p><OpenCrm /></Frame>;
    return <Frame title="Your setup"><Failed error={load.error} onRetry={start} /></Frame>;
  }

  if (state.business_available === false) {
    return <Frame state={state} title="This workspace is paused"><p className="zob-lead">Please contact Zella Voice support to carry on setting up {state.business_name}.</p></Frame>;
  }

  const step = STEP_KEYS.includes(view) ? view : resumeStep(state);
  const back = CAN_GO_BACK.has(step) ? previousStep(step) : null;
  const props = { api, state, email, onState, onComplete, onReload: reload, onRefresh: refresh };

  if (left) {
    const at = SCREENS.find((s) => s.key === resumeStep(state))?.label ?? "the same step";
    return (
      <Frame state={state}>
        <h1 ref={heading} tabIndex={-1}>{left.saved ? "Your place is saved" : "You can come back any time"}</h1>
        <p className="zob-lead">{left.saved
          ? `Next time, you'll start right here, at ${at.toLowerCase()}. Sign in to Zella Voice at any time and choose Finish setting up.`
          : "We couldn't record that you're leaving, but everything you finished is saved. You'll pick up from the first step that isn't done."}</p>
        <ErrorText>{left.retry ? "We couldn't reach Zella Voice just now. Check your connection, then choose Carry on now again." : ""}</ErrorText>
        <div className="zob-actions">
          <button type="button" className="ba-btn primary" disabled={leaving} onClick={carryOn}>{leaving ? "One moment…" : "Carry on now"}</button>
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
          <SidebarBrand caption={state?.business_name} />
        </div>
        {onFinishLater && <button type="button" className="ba-btn sm ghost zob-later" disabled={leaving} onClick={onFinishLater}>{leaving ? "Saving…" : "Finish later"}</button>}
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
