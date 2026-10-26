
import { useEffect, useState } from "react";
import { supabase } from "./supabase";
import OwnerDashboard from "./OwnerDashboard";
import ContinuePlan from "./ContinuePlan";
import Reschedule from "./Reschedule";
import Unsubscribe from "./Unsubscribe";
import WaitlistOffer from "./WaitlistOffer";
import BusinessApp from "./BusinessApp";
import { checkEmail, passwordProblems } from "./formValidation";
import { friendlyAuthError, readEmailLink } from "./authErrors";
import { verifyMfaCode } from "./mfa";
import { maintenanceText, usePlatformInfo } from "./platformInfo";
import "./App.css";


// Public pages that don't need an admin sign-in.
export default function App() {
  // Every email link (invite or reset) is handled on one page: /welcome.
  if (LINK.tokenHash && !window.location.pathname.startsWith("/welcome")) {
    window.location.replace(`/welcome${window.location.search}`);
    return null;
  }
  if (window.location.pathname.startsWith("/continue-plan")) {
    return <ContinuePlan />;
  }
  // Reschedule button from appointment texts and emails (customers, not signed in).
  if (/^\/r\/[0-9a-fA-F]{64}\/?$/.test(window.location.pathname)) {
    return <Reschedule />;
  }
  // Unsubscribe link at the bottom of marketing emails (customers, not signed in).
  if (/^\/u\/[0-9a-fA-F]{32}\/?$/.test(window.location.pathname)) {
    return <Unsubscribe />;
  }
  // Waitlist offer button from a text (customers, not signed in).
  if (/^\/w\/[0-9a-fA-F]{64}\/?$/.test(window.location.pathname)) {
    return <WaitlistOffer />;
  }
  // The client businesses' own CRM.
  if (/^\/(app|welcome)(\/|$)/.test(window.location.pathname)) {
    return <BusinessApp />;
  }
  return <AdminApp />;
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
async function hasAdminAccess() {
  const { data, error } = await supabase.rpc("zella_admin_role");
  if (!error) return typeof data === "string";
  const legacy = await supabase.rpc("is_platform_admin");
  return !legacy.error && legacy.data === true;
}

// The session needs the authenticator code before it may continue.
async function needsMfaCode() {
  const { data, error } = await supabase.auth.mfa.getAuthenticatorAssuranceLevel();
  return !error && data.nextLevel === "aal2" && data.currentLevel !== "aal2";
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
  const [mode, setMode] = useState(LANDING.setup ? "setpassword" : "signin"); // "signin", "reset", "setpassword" or "mfa"
  const [code, setCode] = useState("");
  const platform = usePlatformInfo();

  // Keep an existing owner session after a page refresh,
  // but only if the platform-admin check still passes.
  useEffect(() => {
    let active = true;

    async function restoreSession() {
      try {
        const { data } = await supabase.auth.getSession();
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

        if (isOwner) {
          setIsAuthorized(true);
        } else {
          // Signed in to the business app in this browser. Don't sign them out of
          // it just for opening the admin page; point them to the right place.
          setMessageType("error");
          setMessage(`You're signed in as ${data.session.user.email}, which isn't a Zella admin. Open your business workspace at /app, or sign in below with an admin account.`);
        }
      } catch (error) {
        console.error("Session check failed:", error);
      } finally {
        if (active) setCheckingSession(false);
      }
    }

    restoreSession();

    const { data: listener } = supabase.auth.onAuthStateChange((event) => {
      if (event === "SIGNED_OUT") setIsAuthorized(false);
    });

    return () => {
      active = false;
      listener.subscription.unsubscribe();
    };
  }, []);

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
      setMessage("If that email has a Zella account, a password reset link is on its way. Open the newest email only, once.");
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
      if (!(await hasAdminAccess())) {
        await supabase.auth.signOut();
        setMode("signin");
        throw new Error("Your password is saved, but this account is not an authorized Zella admin yet.");
      }
      window.history.replaceState(null, "", window.location.pathname);
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
      await verifyMfaCode(code);
      if (!(await hasAdminAccess())) {
        await supabase.auth.signOut();
        setMode("signin");
        throw new Error("This account is not authorized to access the Zella Owner Admin.");
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
      if (!(await hasAdminAccess())) {
        await supabase.auth.signOut();
        throw new Error(
          "This account is not authorized to access the Zella Owner Admin."
        );
      }

      setMessageType("success");
      setMessage(`Signed in successfully as ${data.user.email}.`);
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
        <p className="form-description">Checking your session...</p>
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
            <span>zella<span className="brand-ai">ai</span></span>
          </div>

          <div className="brand-message">
            <div className="eyebrow">
              <span className="eyebrow-dot" />
              PLATFORM CONTROL CENTER
            </div>
            <h1>
              Every business.
              <br />
              One <span>intelligent</span>
              <br />
              platform.
            </h1>
            <p>
              Your central command for managing Zella AI businesses,
              AI receptionists, subscriptions and operations.
            </p>

            <div className="feature-list">
              <div className="feature">
                <span className="feature-icon">✳</span>
                <div>
                  <strong>AI-powered operations</strong>
                  <span>Manage your platform from one workspace.</span>
                </div>
              </div>
              <div className="feature">
                <span className="feature-icon">⌘</span>
                <div>
                  <strong>Centralized control</strong>
                  <span>One secure place for platform administration.</span>
                </div>
              </div>
              <div className="feature">
                <span className="feature-icon">◈</span>
                <div>
                  <strong>Built to scale</strong>
                  <span>A unified foundation for multiple industries.</span>
                </div>
              </div>
            </div>
          </div>

          <div className="brand-footer">
            <span>© 2026 Zella AI</span>
            <span>Platform administration</span>
          </div>
        </div>

        <div className="form-panel">
          <div className="mobile-brand">
            {platform.logo_url ? <img src={platform.logo_url} alt={platform.display_name ?? "Zella AI"} style={{ maxHeight: 36 }} /> : <>
            <div className="brand-mark">Z</div>
            <span>zella<span className="brand-ai">ai</span></span></>}
          </div>

          <div className="form-content">
            {maintenanceText(platform) && <div className="login-message error" role="status">{maintenanceText(platform)}</div>}
            {platform.logo_url ? <img src={platform.logo_url} alt={platform.display_name ?? "Zella AI"} style={{ maxHeight: 48, marginBottom: 12 }} /> : <div className="form-symbol">↗</div>}
            <div className="form-eyebrow">OWNER ACCESS</div>
            <h2>{mode === "reset" ? "Reset your password" : mode === "setpassword" ? "Choose your password" : mode === "mfa" ? "Enter your code" : "Welcome back"}</h2>
            <p className="form-description">
              {mode === "reset"
                ? "Enter your email and we'll send you a link to set a new password."
                : mode === "setpassword"
                  ? "You're invited as a Zella admin. Choose a password to finish."
                  : mode === "mfa"
                    ? "Open your authenticator app and enter the 6-digit code for Zella."
                    : platform.login_headline || "Sign in to your Zella platform workspace."}
            </p>

            <form onSubmit={mode === "reset" ? handleReset : mode === "setpassword" ? handleSetPassword : mode === "mfa" ? handleMfa : handleLogin}>
              {mode === "mfa" ? (
                <>
                  <label htmlFor="mfa-code">Authenticator code</label>
                  <div className="input-wrap">
                    <span className="input-icon">#</span>
                    <input id="mfa-code" inputMode="numeric" autoComplete="one-time-code" maxLength={7} value={code}
                      onChange={(e) => setCode(e.target.value)} placeholder="123456" autoFocus required />
                  </div>
                </>
              ) : mode === "setpassword" ? (
                <>
                  <label htmlFor="new-password">New password</label>
                  <div className="input-wrap">
                    <span className="input-icon">♙</span>
                    <input id="new-password" type={showPassword ? "text" : "password"} value={password} onChange={(e) => setPassword(e.target.value)} autoComplete="new-password" required />
                    <button type="button" className="show-password" onClick={() => setShowPassword(!showPassword)} aria-label={showPassword ? "Hide password" : "Show password"}>
                      {showPassword ? "Hide" : "Show"}
                    </button>
                  </div>
                  <label htmlFor="confirm-password">Confirm password</label>
                  <div className="input-wrap">
                    <span className="input-icon">♙</span>
                    <input id="confirm-password" type={showPassword ? "text" : "password"} value={confirmPassword} onChange={(e) => setConfirmPassword(e.target.value)} autoComplete="new-password" required />
                  </div>
                </>
              ) : (
                <>
              <label htmlFor="email">Email address</label>
              <div className="input-wrap">
                <span className="input-icon">✉</span>
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
                <span className="input-icon">♙</span>
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
                {mode === "mfa"
                  ? loading ? "Checking..." : "Verify and continue"
                  : mode === "setpassword"
                  ? loading ? "Saving..." : "Save password and continue"
                  : mode === "reset"
                  ? loading ? "Sending..." : "Send reset link"
                  : loading ? "Verifying access..." : "Sign in to Zella"}
                {!loading && mode === "signin" && <span>→</span>}
              </button>
              {mode === "mfa" ? (
                <button type="button" className="forgot-link" onClick={async () => { await supabase.auth.signOut(); switchMode("signin"); }}>
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
              <span>♢</span>
              <div>
                <strong>Protected owner access</strong>
                <p>
                  Your platform role is verified after sign-in.
                  Only authorized owner accounts can proceed.
                </p>
              </div>
            </div>
          </div>

          <div className="form-footer">
            <span>Secure platform access</span>
            <span>Privacy · Security</span>
          </div>
        </div>
      </section>
    </main>
  );
}
