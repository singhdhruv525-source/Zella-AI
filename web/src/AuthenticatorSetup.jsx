import { useEffect, useId, useRef, useState } from "react";
import { finishMfaEnrollment, startMfaEnrollment } from "./mfa";
import { friendlyAuthError } from "./authErrors";
import "./AuthenticatorSetup.css";

// Adding an authenticator app (two step sign in): the code to scan, the key to type in by hand, the six digit code, and
// Turn on. It uses the same set up calls as the admin sign in and Settings (mfa.js); start and finish can be passed in
// (the owner onboarding journey passes its own api, which is the same calls). It never decides who must use two step
// sign in: the server does.
//   onDone()        called once the authenticator is on
//   submitLabel     the main button's words
export default function AuthenticatorSetup({ start = startMfaEnrollment, finish = finishMfaEnrollment, onDone, submitLabel = "Turn on" }) {
  const [setup, setSetup] = useState(null);
  const [preparing, setPreparing] = useState(true);
  const [code, setCode] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const codeId = useId();
  const errorId = useId();
  const started = useRef(false);

  async function prepare() {
    setPreparing(true);
    setError("");
    try { setSetup(await start()); }
    catch (err) { setError(friendlyAuthError(err)); }
    finally { setPreparing(false); }
  }
  // Start once, even under React's development double effect.
  useEffect(() => { if (!started.current) { started.current = true; prepare(); } }, []); // eslint-disable-line react-hooks/exhaustive-deps

  async function submit(event) {
    event.preventDefault();
    if (!setup) return prepare();
    setBusy(true);
    setError("");
    try {
      await finish(setup.factorId, code);
      setCode("");
      await onDone?.();
    } catch (err) {
      setError(friendlyAuthError(err));
    } finally {
      setBusy(false);
    }
  }

  return (
    <form className="zv-authsetup" onSubmit={submit} noValidate>
      <ol className="zv-authsetup-steps">
        <li>Open an authenticator app on your phone (Google Authenticator, 1Password, Authy and similar).</li>
        <li>Scan this code with the app, or type the key in by hand.</li>
        <li>Enter the six digit code the app shows.</li>
      </ol>
      {preparing ? <p className="zv-authsetup-wait" role="status">Preparing your code…</p> : setup && (
        <div className="zv-authsetup-code">
          <img src={setup.qr} alt="QR code to scan with your authenticator app" width="168" height="168" />
          <p>Can't scan it? Type this key into the app: <code>{setup.secret}</code></p>
        </div>
      )}
      <label className="zv-authsetup-field" htmlFor={codeId}>
        <span>Code from the app</span>
        <input id={codeId} inputMode="numeric" autoComplete="one-time-code" maxLength={7} value={code} placeholder="123456"
          disabled={!setup} aria-invalid={Boolean(error)} aria-describedby={error ? errorId : undefined}
          onChange={(e) => setCode(e.target.value)} />
      </label>
      {error && <p className="zv-authsetup-error" id={errorId} role="alert">{error}</p>}
      <button type="submit" className="ba-btn primary block" disabled={busy || preparing}>
        {busy ? "Checking…" : setup ? submitLabel : "Try again"}
      </button>
    </form>
  );
}
