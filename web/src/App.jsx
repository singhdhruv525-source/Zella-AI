
import BrokenLink from "./BrokenLink";
import NotFound from "./NotFound";
import { publicRoute } from "./publicRoute";
import { useEffect, useRef, useState } from "react";
import { supabase } from "./supabase";
import OwnerDashboard from "./OwnerDashboard";
import ContinuePlan from "./ContinuePlan";
import Reschedule from "./Reschedule";
import Unsubscribe from "./Unsubscribe";
import StatusPage from "./StatusPage";
import LegalPage from "./LegalPage";
import WaitlistOffer from "./WaitlistOffer";
import BusinessApp from "./BusinessApp";
import { checkEmail, passwordProblems } from "./formValidation";
import { friendlyAuthError, readEmailLink } from "./authErrors";
import { finishMfaEnrollment, startMfaEnrollment, verifyMfaCode } from "./mfa";
import { callOwnerFunction } from "./CreateBusinessWizard";
import { maintenanceText, usePlatformInfo } from "./platformInfo";
import "./App.css";
import { Icon, loadBusinessFonts } from "./BusinessUI";

loadBusinessFonts();


// Public pages that don't need an admin sign-in.
export default function App() {
  // Every email link (invite or reset) is handled on one page: /welcome.
  if (LINK.tokenHash && !window.location.pathname.startsWith("/welcome")) {
    window.location.replace(`/welcome${window.location.search}`);
    return null;
  }
  // Which page the address opens: publicRoute.js (tested in publicRoute.test.mjs).
  const route = publicRoute(window.location.pathname, window.location.hostname);
  // app.<domain> is the business CRM: its front page opens the CRM, so customers never land on the admin sign-in.
  // admin.<domain> (or any other address) keeps the admin dashboard at "/". Every other path works on both.
  if (route === "app-home") {
    window.location.replace(`/app${window.location.search}${window.location.hash}`);
    return null;
  }
  if (route === "continue") return <ContinuePlan />;
  // A customer link that was cut short or mistyped (/r/, /u/, /w/) is a customer's page, never the admin sign-in.
  if (route === "broken-link") return <BrokenLink />;
  // Reschedule button from appointment texts and emails (customers, not signed in).
  if (route === "reschedule") return <Reschedule />;
  // Public status page: is Zella Voice working right now (anyone, not signed in).
  if (route === "status") return <StatusPage />;
  // Privacy policy and terms (anyone, not signed in).
  if (route === "privacy" || route === "terms") return <LegalPage kind={route} />;
  // Unsubscribe link at the bottom of marketing emails (customers, not signed in).
  if (route === "unsubscribe") return <Unsubscribe />;
  // Waitlist offer button from a text (customers, not signed in).
  if (route === "waitlist") return <WaitlistOffer />;
  // The client businesses' own CRM.
  if (route === "business") return <BusinessApp />;
  // An address that matches no page: "Page not found" for someone signed out, never the admin sign in.
  if (route === "unknown") return <UnknownAddress />;
  return <AdminApp />;
}

// Someone signed in keeps what they had before (the admin dashboard, which shows its own "Page not found"); anyone
// else sees the public "Page not found". Nothing shows until the saved session has been read; a check that fails is
// said plainly with Try again (never shown as signed out), and signing out here shows "Page not found", not the admin
// sign in.
function UnknownAddress() {
  const [signedIn, setSignedIn] = useState(null);   // null while checking, true, false, or "unavailable"
  const [attempt, setAttempt] = useState(0);
  useEffect(() => {
    let live = true;
    supabase.auth.getSession().then(
      ({ data, error }) => { if (live) setSignedIn(error ? "unavailable" : Boolean(data?.session)); },
      () => { if (live) setSignedIn("unavailable"); },
    );
    const { data: listener } = supabase.auth.onAuthStateChange((event) => {
      if (event === "SIGNED_OUT" && live) setSignedIn(false);
    });
    return () => { live = false; listener?.subscription?.unsubscribe(); };
  }, [attempt]);
  if (signedIn === null) return null;
  if (signedIn === "unavailable") {
    return <NotFound unavailable onRetry={() => { setSignedIn(null); setAttempt((n) => n + 1); }} />;
  }
  return signedIn ? <AdminApp /> : <NotFound />;
}

// What the email link brought us here with (read before the sign-in library
// tidies the address bar).
const LINK = readEmailLink();
const LANDING = {
  // An invitation (or reset) link that worked: the person now picks a password.
  setup: !LINK.error && !LINK.tokenHash && ["invite", "recovery"].includes(LINK.type),
  error: LINK.error
    ? `${LINK.error} Ask the person who invited you to send a new one, or choose Forgot your password.`
    : "",
};

// Any active platform role may open the dashboard; what each role may do is checked on the server.
// Falls back to the older check until sql/zella_settings_system.sql is applied.
// Is the signed in person a Zella Voice admin, and have they set up two step sign in? Asked of the admin function
// (me_admin), which reads the role with the server key: an admin who hasn't set up an authenticator yet is refused by
// the database itself, so the database can't be asked (ACC-01, ACC-34). Returns true, false, "setup" (admin, no
// authenticator yet) or "unavailable" (couldn't tell; callers must not sign the person out on it).
async function hasAdminAccess() {
  try {
    const me = await callOwnerFunction("me_admin");
    if (!me || typeof me.role !== "string") return "unavailable";
    return me.mfa === false ? "setup" : true;
  } catch (error) {
    if (error.code === "MFA_SETUP_REQUIRED") return "setup";
    if (error.status === 403 && !error.code) return false;   // "Platform admin access required"
    return "unavailable";
  }
}

// The session needs the authenticator code before it may continue. If the check itself fails, nothing opens (it fails
// closed): the error reaches the caller's catch, which leaves the admin page locked and says why.
async function needsMfaCode() {
  const { data, error } = await supabase.auth.mfa.getAuthenticatorAssuranceLevel();
  if (error || !data) throw new Error("We couldn't check your two step sign in. Please try again.");
  return data.nextLevel === "aal2" && data.currentLevel !== "aal2";
}

function AdminApp() {
  const [email, setEmail] = useState("");
  const [emailTouched, setEmailTouched] = useState(false);
  const [password, setPassword] = useState("");
  const [showPassword, setShowPassword] = useState(false);
  const [loading, setLoading] = useState(false);
  const [message, setMessage] = useState(LANDING.error);
  const [messageType, setMessageType] = useState("error");
  const [confirmPassword, setConfirmPassword] = useState("");
  const [isAuthorized, setIsAuthorized] = useState(false);
  const [checkingSession, setCheckingSession] = useState(true);
  const [mode, setMode] = useState(LANDING.setup ? "setpassword" : "signin"); // "signin", "reset", "setpassword", "mfa" or "mfasetup"
  const [code, setCode] = useState("");
  const [mfaVerified, setMfaVerified] = useState(false);
  const [mfaSetup, setMfaSetup] = useState(null);   // { factorId, qr, secret } while setting up an authenticator
  // Bumped on every sign out or account switch: an answer that arrives for an earlier sign in is ignored, so it can
  // never open the dashboard for a session that has gone.
  const flow = useRef(0);
  const platform = usePlatformInfo();

  // Keep an existing owner session after a page refresh,
  // but only if the platform-admin check still passes.
  useEffect(() => {
    let active = true;

    async function restoreSession() {
      try {
        const { data, error: sessionError } = await supabase.auth.getSession();
        // a failed refresh returns an error with no session: say so instead of showing a plain sign-in screen; on the
        // invitation's password step the expired-link guidance below already covers it
        if (sessionError && !LANDING.setup) {
          if (/refresh[ _-]?token/i.test(`${sessionError.code ?? ""} ${sessionError.message ?? sessionError}`)) {
            throw new Error("Your saved session couldn't be restored. Please sign in again.");
          }
          throw sessionError;
        }
        if (LANDING.setup) {
          // From an invitation: stay on the "choose a password" step.
          if (!data.session && active) {
            setMode("signin");
            setMessageType("error");
            setMessage("This link has expired or was already used. Ask for a new invitation, or choose Forgot your password.");
          }
          return;
        }
        if (!data.session) return;

        if (await needsMfaCode()) {
          if (active) { setMode("mfa"); setEmail(data.session.user.email ?? ""); }
          return;
        }
        const isOwner = await hasAdminAccess();

        if (!active) return;

        if (isOwner === "setup") {
          setEmail(data.session.user.email ?? "");
          await beginMfaSetup();
        } else if (isOwner === "unavailable") {
          setMessageType("error");
          setMessage("Admin access couldn't be checked. Please try signing in again.");
        } else if (isOwner) {
          setIsAuthorized(true);
        } else {
          // Signed in to the business app in this browser. Don't sign them out of
          // it just for opening the admin page; point them to the right place.
          setMessageType("error");
          setMessage(`You're signed in as ${data.session.user.email}, which isn't a Zella Voice admin. Open your business workspace at /app, or sign in below with an admin account.`);
        }
      } catch (error) {
        console.error("Session check failed:", error);
        if (active) {
          setMessageType("error");
          setMessage(friendlyAuthError(error));
        }
      } finally {
        if (active) setCheckingSession(false);
      }
    }

    restoreSession();

    const { data: listener } = supabase.auth.onAuthStateChange((event) => {
      if (event === "SIGNED_OUT") { flow.current++; setIsAuthorized(false); setMfaVerified(false); setMfaSetup(null); setLoading(false); }
    });

    return () => {
      active = false;
      listener.subscription.unsubscribe();
    };
  }, []);

  // An admin without an authenticator is walked through setting one up before anything opens (ACC-01).
  async function beginMfaSetup() {
    const mine = flow.current;
    setMode("mfasetup");
    setCode("");
    setMessage("");
    try { const setup = await startMfaEnrollment(); if (mine === flow.current) setMfaSetup(setup); }
    catch (error) { if (mine === flow.current) { setMessageType("error"); setMessage(friendlyAuthError(error)); } }
  }

  async function handleMfaSetup(event) {
    event.preventDefault();
    setMessage("");
    setLoading(true);
    const mine = flow.current;
    try {
      if (!mfaSetup) { await beginMfaSetup(); return; }
      await finishMfaEnrollment(mfaSetup.factorId, code);
      const access = await hasAdminAccess();
      if (mine !== flow.current) return;   // signed out or switched account meanwhile
      if (access !== true) throw new Error("Two step sign in is set up, but admin access couldn't be checked. Please sign in again.");
      setMfaSetup(null);
      setCode("");
      setIsAuthorized(true);
    } catch (error) {
      if (mine !== flow.current) return;
      setMessageType("error");
      setMessage(friendlyAuthError(error));
    } finally {
      if (mine === flow.current) setLoading(false);
    }
  }

  async function handleSignOut() {
    await supabase.auth.signOut();
    setIsAuthorized(false);
    setPassword("");
    setMessage("");
  }

  async function handleReset(event) {
    event.preventDefault();
    setMessage("");
    setEmailTouched(true);
    const problem = checkEmail(email, { required: true });
    if (problem) {
      setMessageType("error");
      setMessage(problem);
      return;
    }
    setLoading(true);
    try {
      const { error } = await supabase.auth.resetPasswordForEmail(email.trim(), {
        redirectTo: `${window.location.origin}/welcome`,
      });
      if (error) throw error;
      // Same message whether or not the email exists, so accounts can't be discovered.
      setMessageType("success");
      setMessage("If that email has a Zella Voice account, a password reset link is on its way. Open the newest email only, once.");
    } catch (error) {
      setMessageType("error");
      setMessage(friendlyAuthError(error));
    } finally {
      setLoading(false);
    }
  }

  async function handleSetPassword(event) {
    event.preventDefault();
    setMessage("");
    const missing = passwordProblems(password);
    if (missing.length) {
      setMessageType("error");
      setMessage(`Your password still needs: ${missing.join(", ")}.`);
      return;
    }
    if (password !== confirmPassword) {
      setMessageType("error");
      setMessage("The two passwords don't match.");
      return;
    }
    setLoading(true);
    try {
      const { error } = await supabase.auth.updateUser({ password });
      if (error) throw error;
      window.history.replaceState(null, "", window.location.pathname + window.location.search);
      // The save is complete even if the access check fails. Retry through sign-in.
      setMode("signin");
      setPassword("");
      setConfirmPassword("");
      const access = await hasAdminAccess();
      if (access === "unavailable") throw new Error("Admin access couldn't be checked. Please try again.");
      if (!access) {
        await supabase.auth.signOut();
        setMode("signin");
        throw new Error("Your password is saved, but this account is not an authorized Zella Voice admin yet.");
      }
      setPassword("");
      setConfirmPassword("");
      setIsAuthorized(true);
    } catch (error) {
      setMessageType("error");
      setMessage(friendlyAuthError(error));
    } finally {
      setLoading(false);
    }
  }

  async function handleMfa(event) {
    event.preventDefault();
    setMessage("");
    setLoading(true);
    try {
      if (!mfaVerified) {
        await verifyMfaCode(code);
        setMfaVerified(true);
        setCode("");
      } else if (await needsMfaCode()) {
        setMfaVerified(false);
        throw new Error("Please enter a new authenticator code.");
      }
      const access = await hasAdminAccess();
      if (access === "unavailable") throw new Error("Admin access couldn't be checked. Please try again.");
      if (access === "setup") { await beginMfaSetup(); return; }
      if (!access) {
        await supabase.auth.signOut();
        setMode("signin");
        throw new Error("This account isn't a Zella Voice admin.");
      }
      setCode("");
      setIsAuthorized(true);
    } catch (error) {
      setMessageType("error");
      setMessage(friendlyAuthError(error));
    } finally {
      setLoading(false);
    }
  }

  function switchMode(next) {
    setMode(next);
    setMfaVerified(false);
    setMessage("");
    setEmailTouched(false);
  }

  async function handleLogin(event) {
    event.preventDefault();
    setMessage("");

    setEmailTouched(true);
    if (!email.trim() || !password) {
      setMessage("Enter your email and password.");
      return;
    }
    if (checkEmail(email)) {
      setMessage(checkEmail(email));
      return;
    }

    setLoading(true);

    try {
      const { data, error } = await supabase.auth.signInWithPassword({
        email: email.trim(),
        password,
      });

      if (error) throw error;

      // Authentication alone does not grant platform-owner access.
      if (await needsMfaCode()) {
        setPassword("");
        setMode("mfa");
        setMessage("");
        return;
      }
      const access = await hasAdminAccess();
      if (access === "unavailable") throw new Error("Admin access couldn't be checked. Please try again.");
      if (access === "setup") { setPassword(""); await beginMfaSetup(); return; }
      if (!access) {
        await supabase.auth.signOut();
        throw new Error("This account isn't a Zella Voice admin.");
      }

      setMessageType("success");
      setMessage(`Signed in as ${data.user.email}.`);
      setIsAuthorized(true);
    } catch (error) {
      setMessageType("error");
      setMessage(friendlyAuthError(error));
    } finally {
      setLoading(false);
    }
  }

  if (checkingSession) {
    return (
      <main className="login-page">
        <p className="form-description">Checking your session…</p>
      </main>
    );
  }

  if (isAuthorized) {
    return <OwnerDashboard onSignOut={handleSignOut} />;
  }

  return (
    <main className="login-page">
      <div className="ambient ambient-one" />
      <div className="ambient ambient-two" />

      <section className="login-layout">
        <div className="brand-panel">
          <div className="brand">
            <div className="brand-mark">Z</div>
            <span>Zella <span className="brand-ai">Voice</span></span>
          </div>

          <div className="brand-message">
            <div className="eyebrow">
              <span className="eyebrow-dot" />
              Platform administration
            </div>
            <h1>Zella Voice admin</h1>
            <p>
              Sign in to manage businesses, AI receptionists, plans and operations.
            </p>
          </div>

          <div className="brand-footer">
            <span>© 2026 Zella Voice</span>
            <span>Platform administration</span>
          </div>
        </div>

        <div className="form-panel">
          <div className="mobile-brand">
            {platform.logo_url ? <img src={platform.logo_url} alt={platform.display_name ?? "Zella Voice"} style={{ maxHeight: 36 }} /> : <>
            <div className="brand-mark">Z</div>
            <span>Zella <span className="brand-ai">Voice</span></span></>}
          </div>

          <div className="form-content">
            {maintenanceText(platform) && <div className="login-message error" role="status">{maintenanceText(platform)}</div>}
            {platform.logo_url ? <img src={platform.logo_url} alt={platform.display_name ?? "Zella Voice"} style={{ maxHeight: 48, marginBottom: 12 }} /> : <div className="form-symbol"><Icon name="login" /></div>}
            <div className="form-eyebrow">Admin access</div>
            <h2>{mode === "reset" ? "Reset your password" : mode === "setpassword" ? "Choose your password" : mode === "mfasetup" ? "Set up two step sign in" : mode === "mfa" ? mfaVerified ? "Check admin access" : "Enter your code" : "Welcome back"}</h2>
            <p className="form-description">
              {mode === "reset"
                ? "Enter your email and we'll send you a link to set a new password."
                : mode === "setpassword"
                  ? "You're invited as a Zella Voice admin. Choose a password to finish."
                  : mode === "mfasetup"
                    ? "Every Zella Voice admin signs in with a password and a code from an authenticator app (Google Authenticator, 1Password, Authy and similar). Scan the code below with the app, then enter the six digit code it shows."
                  : mode === "mfa"
                    ? mfaVerified ? "Your code was verified. Check your admin access again." : "Open your authenticator app and enter the six digit code for Zella Voice."
                    : platform.login_headline || "Sign in to your Zella Voice platform workspace."}
            </p>

            <form onSubmit={mode === "reset" ? handleReset : mode === "setpassword" ? handleSetPassword : mode === "mfasetup" ? handleMfaSetup : mode === "mfa" ? handleMfa : handleLogin}>
              {mode === "mfasetup" ? (
                <>
                  {mfaSetup ? (
                    <div className="mfa-setup">
                      <img src={mfaSetup.qr} alt="QR code to scan with your authenticator app" width="180" height="180" />
                      <p className="form-description">Can't scan it? Type this key into the app: <code>{mfaSetup.secret}</code></p>
                    </div>
                  ) : <p className="form-description">Preparing your code…</p>}
                  <label htmlFor="mfa-setup-code">Code from the app</label>
                  <div className="input-wrap">
                    <span className="input-icon"><Icon name="pin" size="sm" /></span>
                    <input id="mfa-setup-code" inputMode="numeric" autoComplete="one-time-code" maxLength={7} value={code}
                      onChange={(e) => setCode(e.target.value)} placeholder="123456" required={Boolean(mfaSetup)} />
                  </div>
                </>
              ) : mode === "mfa" ? (mfaVerified ? null : (
                <>
                  <label htmlFor="mfa-code">Authenticator code</label>
                  <div className="input-wrap">
                    <span className="input-icon"><Icon name="pin" size="sm" /></span>
                    <input id="mfa-code" inputMode="numeric" autoComplete="one-time-code" maxLength={7} value={code}
                      onChange={(e) => setCode(e.target.value)} placeholder="123456" autoFocus required />
                  </div>
                </>
              )) : mode === "setpassword" ? (
                <>
                  <label htmlFor="new-password">New password</label>
                  <div className="input-wrap">
                    <span className="input-icon"><Icon name="lock" size="sm" /></span>
                    <input id="new-password" type={showPassword ? "text" : "password"} value={password} onChange={(e) => setPassword(e.target.value)} autoComplete="new-password" required />
                    <button type="button" className="show-password" onClick={() => setShowPassword(!showPassword)} aria-label={showPassword ? "Hide password" : "Show password"}>
                      {showPassword ? "Hide" : "Show"}
                    </button>
                  </div>
                  <label htmlFor="confirm-password">Confirm password</label>
                  <div className="input-wrap">
                    <span className="input-icon"><Icon name="lock" size="sm" /></span>
                    <input id="confirm-password" type={showPassword ? "text" : "password"} value={confirmPassword} onChange={(e) => setConfirmPassword(e.target.value)} autoComplete="new-password" required />
                  </div>
                </>
              ) : (
                <>
              <label htmlFor="email">Email address</label>
              <div className="input-wrap">
                <span className="input-icon"><Icon name="mail" size="sm" /></span>
                <input
                  id="email"
                  type="email"
                  placeholder="you@company.com"
                  value={email}
                  onChange={(event) => setEmail(event.target.value)}
                  onBlur={() => setEmailTouched(true)}
                  autoComplete="username"
                  aria-invalid={Boolean(emailTouched && checkEmail(email))}
                  aria-describedby={emailTouched && checkEmail(email) ? "email-error" : undefined}
                  required
                />
              </div>
              {emailTouched && checkEmail(email) && (
                <p id="email-error" className="field-error" role="alert">{checkEmail(email)}</p>
              )}
                </>
              )}

              {mode === "signin" && (
                <>
              <div className="password-heading">
                <label htmlFor="password">Password</label>
              </div>
              <div className="input-wrap">
                <span className="input-icon"><Icon name="lock" size="sm" /></span>
                <input
                  id="password"
                  type={showPassword ? "text" : "password"}
                  placeholder="Enter your password"
                  value={password}
                  onChange={(event) => setPassword(event.target.value)}
                  autoComplete="current-password"
                  required
                />
                <button
                  type="button"
                  className="show-password"
                  onClick={() => setShowPassword(!showPassword)}
                  aria-label={showPassword ? "Hide password" : "Show password"}
                >
                  {showPassword ? "Hide" : "Show"}
                </button>
              </div>

                </>
              )}
              <button className="login-button" type="submit" disabled={loading}>
                {mode === "mfasetup"
                  ? loading ? "Checking…" : mfaSetup ? "Turn on and continue" : "Try again"
                  : mode === "mfa"
                  ? loading ? "Checking…" : mfaVerified ? "Check access again" : "Verify and continue"
                  : mode === "setpassword"
                  ? loading ? "Saving…" : "Save password and continue"
                  : mode === "reset"
                  ? loading ? "Sending…" : "Send reset link"
                  : loading ? "Verifying access…" : "Sign in to Zella Voice"}
                {!loading && mode === "signin" && <span>→</span>}
              </button>
              {mode === "mfa" || mode === "mfasetup" ? (
                <button type="button" className="forgot-link" onClick={async () => { flow.current++; setLoading(false); await supabase.auth.signOut(); setMfaSetup(null); switchMode("signin"); }}>
                  ← Use a different account
                </button>
              ) : mode === "setpassword" ? null : mode === "signin" ? (
                <button type="button" className="forgot-link" onClick={() => switchMode("reset")}>
                  Forgot your password?
                </button>
              ) : (
                <button type="button" className="forgot-link" onClick={() => switchMode("signin")}>
                  ← Back to sign in
                </button>
              )}
            </form>

            {message && (
              <div
                className={`login-message ${messageType}`}
                role="status"
              >
                {message}
              </div>
            )}

            <div className="security-note">
              <span><Icon name="shield" size="sm" /></span>
              <div>
                <strong>Protected admin access</strong>
                <p>
                  Your admin role is checked after you sign in, and every admin uses two step sign in.
                </p>
              </div>
            </div>
          </div>

          <div className="form-footer">
            <span>Secure platform access</span>
            <span><a href="/privacy">Privacy</a> · <a href="/terms">Terms</a> · <a href="/status">Status</a></span>
          </div>
        </div>
      </section>
    </main>
  );
}
