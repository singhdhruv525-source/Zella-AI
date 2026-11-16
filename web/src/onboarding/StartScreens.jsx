import { useState } from "react";
import { ConfirmPasswordField, PasswordField } from "../formFields";
import { passwordProblems } from "../formValidation";
import { friendlyAuthError } from "../authErrors";
import AuthenticatorSetup from "../AuthenticatorSetup";
import { Icon } from "../BusinessUI";
import { Actions, ErrorText, useAction } from "./kit";
import { SCREENS, securityPart } from "./steps";

// Screens 1 and 2: Welcome, then the password and the authenticator (contract step "security").

const AHEAD = {
  security: "Choose a password and add a code from your phone, so only you can sign in.",
  details: "Check what the Zella Voice team set up for you, one part at a time.",
  identity: "Upload your photo ID and business registration so we know it's really you.",
  plan: "See your plan, its price and what's included.",
  payment: "Pay for your plan when payment opens.",
  done: "See what happens next and open your CRM.",
};

export function WelcomeScreen({ state, onComplete }) {
  const action = useAction();
  return (
    <>
      <p className="zob-lead">
        Your AI receptionist for <strong>{state.business_name}</strong> is almost ready. Setting up takes about ten
        minutes, and you can stop and come back at any step.
      </p>
      <h2 className="zob-subhead">The steps ahead</h2>
      <ol className="zob-ahead">
        {SCREENS.slice(1).map((s, i) => (
          <li key={s.key}>
            <span className="zob-ahead-n" aria-hidden="true">{i + 2}</span>
            <div><strong>{s.label}</strong><span>{AHEAD[s.key]}</span></div>
          </li>
        ))}
      </ol>
      <ErrorText>{action.error}</ErrorText>
      <Actions><button type="button" className="ba-btn primary" disabled={action.busy} onClick={() => action.run(() => onComplete("welcome"))}>{action.busy ? "One moment…" : "Get started"}</button></Actions>
    </>
  );
}

// The three parts follow what the server reads from the sign in records (state.security).
export function SecurityScreen({ api, state, email, onRefresh, onComplete }) {
  const part = securityPart(state.security);
  return (
    <>
      <ol className="zob-parts" aria-label="Parts of this step">
        <Part on={part === "password"} done={part !== "password"}>Password</Part>
        <Part on={part === "authenticator" || part === "code"} done={part === "ready"}>Authenticator app</Part>
      </ol>
      {part === "password" && <PasswordPart api={api} email={email} onDone={onRefresh} />}
      {part === "authenticator" && <AuthenticatorPart api={api} onDone={onRefresh} />}
      {part === "code" && <CodePart api={api} onDone={onRefresh} />}
      {part === "ready" && <ReadyPart onComplete={onComplete} />}
    </>
  );
}

function Part({ on, done, children }) {
  return (
    <li className={on ? "on" : done ? "done" : ""} aria-current={on ? "step" : undefined}>
      <Icon name={done ? "check_circle" : "radio_button_unchecked"} size="sm" />
      <span>{children}</span>
      <span className="zob-sr">{done ? ", done" : on ? ", now" : ", next"}</span>
    </li>
  );
}

function PasswordPart({ api, email, onDone }) {
  const [password, setPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  const [tried, setTried] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  async function save(event) {
    event.preventDefault();
    setTried(true); setError("");
    const missing = passwordProblems(password);
    if (missing.length) return setError(`Your password still needs: ${missing.join(", ")}.`);
    if (password !== confirm) return setError("The two passwords don't match.");
    setBusy(true);
    try { await api.setPassword(password); await onDone(); }
    catch (err) { setError(friendlyAuthError(err)); setBusy(false); }
  }
  return (
    <form className="ba-form zob-form" onSubmit={save} noValidate>
      <p className="zob-lead">{email ? <>You'll sign in with <strong>{email}</strong> and this password.</> : "Choose the password you'll sign in with."}</p>
      <div className="ba-field">
        <label htmlFor="zob-password">New password</label>
        <PasswordField id="zob-password" label="New password" value={password} onChange={setPassword} showErrors={tried} />
      </div>
      <div className="ba-field">
        <label htmlFor="zob-password2">Confirm password</label>
        <ConfirmPasswordField id="zob-password2" label="Confirm password" value={confirm} password={password} onChange={setConfirm} showErrors={tried} />
      </div>
      <ErrorText>{error}</ErrorText>
      <Actions><button type="submit" className="ba-btn primary" disabled={busy}>{busy ? "Saving…" : "Save password and continue"}</button></Actions>
    </form>
  );
}

function AuthenticatorPart({ api, onDone }) {
  return (
    <>
      <p className="zob-lead">Each time you sign in, you'll enter your password and then a code from an app on your phone. It keeps your business and your customers' details safe, even if someone learns your password.</p>
      <AuthenticatorSetup start={api.startMfa} finish={api.finishMfa} submitLabel="Turn on and continue" onDone={onDone} />
    </>
  );
}

// An authenticator is set up but this session hasn't entered a code yet (for example, signed in on a new device).
function CodePart({ api, onDone }) {
  const [code, setCode] = useState("");
  const action = useAction();
  return (
    <form className="ba-form zob-form" onSubmit={(e) => { e.preventDefault(); action.run(async () => { await api.verifyMfa(code); await onDone(); }); }}>
      <p className="zob-lead">Open your authenticator app and enter the six digit code for Zella Voice.</p>
      <div className="ba-field">
        <label htmlFor="zob-code">Authenticator code</label>
        <input id="zob-code" inputMode="numeric" autoComplete="one-time-code" maxLength={7} value={code} onChange={(e) => setCode(e.target.value)} />
      </div>
      <ErrorText>{action.error}</ErrorText>
      <Actions><button type="submit" className="ba-btn primary" disabled={action.busy}>{action.busy ? "Checking…" : "Verify and continue"}</button></Actions>
    </form>
  );
}

function ReadyPart({ onComplete }) {
  const action = useAction();
  return (
    <>
      <div className="zob-done-note" role="status"><Icon name="verified_user" /><span>Your password and two step sign in are set up.</span></div>
      <ErrorText>{action.error}</ErrorText>
      <Actions><button type="button" className="ba-btn primary" disabled={action.busy} onClick={() => action.run(() => onComplete("security"))}>{action.busy ? "One moment…" : "Continue"}</button></Actions>
    </>
  );
}
