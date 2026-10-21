
import { useEffect, useState } from "react";
import { supabase } from "./supabase";
import OwnerDashboard from "./OwnerDashboard";
import ContinuePlan from "./ContinuePlan";
import BusinessApp from "./BusinessApp";
import "./App.css";


// Public pages that don't need an admin sign-in.
export default function App() {
  if (window.location.pathname.startsWith("/continue-plan")) {
    return <ContinuePlan />;
  }
  // The client businesses' own CRM.
  if (/^\/(app|welcome)(\/|$)/.test(window.location.pathname)) {
    return <BusinessApp />;
  }
  return <AdminApp />;
}

function AdminApp() {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [showPassword, setShowPassword] = useState(false);
  const [loading, setLoading] = useState(false);
  const [message, setMessage] = useState("");
  const [messageType, setMessageType] = useState("error");
  const [isAuthorized, setIsAuthorized] = useState(false);
  const [checkingSession, setCheckingSession] = useState(true);

  // Keep an existing owner session after a page refresh,
  // but only if the platform-admin check still passes.
  useEffect(() => {
    let active = true;

    async function restoreSession() {
      try {
        const { data } = await supabase.auth.getSession();
        if (!data.session) return;

        const { data: isOwner, error } = await supabase.rpc("is_platform_admin");

        if (!active) return;

        if (!error && isOwner === true) {
          setIsAuthorized(true);
        } else {
          await supabase.auth.signOut();
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

  async function handleLogin(event) {
    event.preventDefault();
    setMessage("");

    if (!email.trim() || !password) {
      setMessage("Enter your email and password.");
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
      const { data: isOwner, error: roleError } =
        await supabase.rpc("is_platform_admin");

      if (roleError || isOwner !== true) {
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
      setMessage(error.message || "Sign-in failed. Please try again.");
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
            <div className="brand-mark">Z</div>
            <span>zella<span className="brand-ai">ai</span></span>
          </div>

          <div className="form-content">
            <div className="form-symbol">↗</div>
            <div className="form-eyebrow">OWNER ACCESS</div>
            <h2>Welcome back</h2>
            <p className="form-description">
              Sign in to your Zella platform workspace.
            </p>

            <form onSubmit={handleLogin}>
              <label htmlFor="email">Email address</label>
              <div className="input-wrap">
                <span className="input-icon">✉</span>
                <input
                  id="email"
                  type="email"
                  placeholder="you@company.com"
                  value={email}
                  onChange={(event) => setEmail(event.target.value)}
                  autoComplete="username"
                  required
                />
              </div>

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

              <button className="login-button" type="submit" disabled={loading}>
                {loading ? "Verifying access..." : "Sign in to Zella"}
                {!loading && <span>→</span>}
              </button>
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
