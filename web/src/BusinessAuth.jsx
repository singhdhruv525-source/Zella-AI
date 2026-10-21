import { useEffect, useState } from "react";
import "./BusinessApp.css";
import { supabase } from "./supabase";
import { ConfirmPasswordField, EmailField, PasswordField } from "./formFields";
import { checkEmail, passwordProblems } from "./formValidation";

// Sign-in, forgotten password and the welcome (set password) page for
// business owners and staff. Platform admins use the admin sign-in at "/".
function AuthCard({ eyebrow, title, description, children }) {
  return (
    <main className="ba-auth">
        <section className="ba-auth-card">
          <div className="ba-brand">
            <div className="ba-logo">Z</div>
            <div>
              <div className="ba-brand-name">Zella AI</div>
              <div className="ba-brand-sub">Your business workspace</div>
            </div>
          </div>
          {eyebrow && <div className="ba-eyebrow">{eyebrow}</div>}
          <h1>{title}</h1>
          {description && <p className="ba-auth-description">{description}</p>}
          {children}
        </section>
    </main>
  );
}

// Sign in with an existing Google, Microsoft or Apple account, or the company's
// Okta. Each provider must be switched on in Supabase (Authentication, Providers).
const SOCIAL = [
  { id: "google", label: "Google (Gmail)", provider: "google" },
  { id: "microsoft", label: "Microsoft (Outlook)", provider: "azure", scopes: "email" },
  { id: "apple", label: "Apple", provider: "apple" },
  { id: "okta", label: "Okta (company sign-in)", sso: true },
];

// Each logo is an official file you add to web/public/auth/ (google.svg, microsoft.svg,
// apple.svg, okta.svg). Until a file exists, the button simply shows its text.
function ProviderLogo({ id }) {
  const [missing, setMissing] = useState(false);
  if (missing) return null;
  return <img className="ba-social-logo" src={`/auth/${id}.svg`} alt="" width="18" height="18" onError={() => setMissing(true)} />;
}

function SocialSignIn({ email, setError, disabled }) {
  const [working, setWorking] = useState("");

  async function go(option) {
    setError("");
    setWorking(option.id);
    try {
      const redirectTo = `${window.location.origin}/app`;
      if (option.sso) {
        const problem = checkEmail(email, { required: true });
        if (problem) throw new Error(`Enter your work email above first, then choose Okta. ${problem}`);
        const { data, error } = await supabase.auth.signInWithSSO({ domain: email.trim().split("@")[1].toLowerCase(), options: { redirectTo } });
        if (error) throw error;
        if (data?.url) window.location.assign(data.url);
        return;
      }
      const { error } = await supabase.auth.signInWithOAuth({
        provider: option.provider,
        options: { redirectTo, ...(option.scopes ? { scopes: option.scopes } : {}) },
      });
      if (error) throw error;
      // The browser is on its way to the provider. If it doesn't leave, unlock the buttons.
      setTimeout(() => setWorking(""), 8000);
    } catch (err) {
      const name = option.label.split(" (")[0];
      setError(
        /not enabled|unsupported provider|provider is not|no sso provider/i.test(err.message)
          ? `${name} sign-in isn't switched on for this workspace yet. Use your email and password, or ask the Zella team.`
          : err.message
      );
      setWorking("");
    }
  }

  return (
    <div className="ba-social">
      <div className="ba-social-divider"><span>or continue with</span></div>
      <div className="ba-social-grid">
        {SOCIAL.map((option) => (
          <button key={option.id} type="button" className="ba-btn ba-social-btn" disabled={disabled || Boolean(working)} onClick={() => go(option)}>
            <ProviderLogo id={option.id} />
            <span>{working === option.id ? "Opening..." : option.label}</span>
          </button>
        ))}
      </div>
    </div>
  );
}

export function BusinessSignIn() {
  const [mode, setMode] = useState("signin");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");

  async function signIn(event) {
    event.preventDefault();
    setBusy(true);
    setError("");
    try {
      const { error: signInError } = await supabase.auth.signInWithPassword({
        email: email.trim(),
        password,
      });
      if (signInError) throw signInError;
    } catch (err) {
      setError(
        /invalid login/i.test(err.message)
          ? "That email and password don't match. Try again or reset your password."
          : err.message
      );
    } finally {
      setBusy(false);
    }
  }

  async function sendReset(event) {
    event.preventDefault();
    setBusy(true);
    setError("");
    try {
      const { error: resetError } = await supabase.auth.resetPasswordForEmail(email.trim(), {
        redirectTo: `${window.location.origin}/welcome`,
      });
      if (resetError) throw resetError;
      // Same message whether or not the email exists, so accounts can't be discovered.
      setNotice("If that email has a Zella account, a password reset link is on its way.");
    } catch (err) {
      setError(err.message);
    } finally {
      setBusy(false);
    }
  }

  if (mode === "reset") {
    return (
      <AuthCard
        eyebrow="RESET PASSWORD"
        title="Forgot your password?"
        description="Enter your email and we'll send you a link to set a new one."
      >
        <form className="ba-form" onSubmit={sendReset}>
          <label className="ba-field">
            <span>Email</span>
            <EmailField value={email} onChange={setEmail} required autoComplete="email" />
          </label>
          {notice && <div className="ba-notice">{notice}</div>}
          {error && <div className="ba-error">{error}</div>}
          <button type="submit" className="ba-btn primary block" disabled={busy || !email.trim()}>
            {busy ? "Sending..." : "Send reset link"}
          </button>
          <button type="button" className="ba-link ba-center" onClick={() => { setMode("signin"); setNotice(""); setError(""); }}>
            ← Back to sign in
          </button>
        </form>
      </AuthCard>
    );
  }

  return (
    <AuthCard eyebrow="YOUR BUSINESS" title="Sign in to Zella" description="Your calls, customers and AI receptionist in one place.">
      <form className="ba-form" onSubmit={signIn}>
        <label className="ba-field">
          <span>Email</span>
          <EmailField value={email} onChange={setEmail} required autoComplete="username" />
        </label>
        <label className="ba-field">
          <span>Password</span>
          <input type="password" required autoComplete="current-password" value={password} onChange={(e) => setPassword(e.target.value)} />
        </label>
        {error && <div className="ba-error">{error}</div>}
        <button type="submit" className="ba-btn primary block" disabled={busy}>
          {busy ? "Signing in..." : "Sign in"}
        </button>
        <button type="button" className="ba-link ba-center" onClick={() => { setMode("reset"); setError(""); }}>
          Forgot your password?
        </button>
        <SocialSignIn email={email} setError={setError} disabled={busy} />
      </form>
    </AuthCard>
  );
}

// Opened from the invitation email or a password-reset email. Supabase signs
// the person in from the link; here they choose their password.
export function Welcome() {
  const [state, setState] = useState("checking");
  const [linkError, setLinkError] = useState("");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  useEffect(() => {
    // Expired or already-used links come back with an error in the URL.
    const params = new URLSearchParams(window.location.hash.replace(/^#/, "") || window.location.search);
    const description = params.get("error_description");
    if (description) {
      setLinkError(description.replace(/\+/g, " "));
      setState("invalid");
      return;
    }

    let active = true;
    supabase.auth.getSession().then(({ data }) => {
      if (!active) return;
      if (data.session) {
        setEmail(data.session.user.email ?? "");
        setState("ready");
      } else {
        setState("invalid");
      }
    });
    return () => {
      active = false;
    };
  }, []);

  async function save(event) {
    event.preventDefault();
    setError("");
    const missing = passwordProblems(password);
    if (missing.length) {
      setError(`Your password still needs: ${missing.join(", ")}.`);
      return;
    }
    if (password !== confirm) {
      setError("The two passwords don't match.");
      return;
    }

    setBusy(true);
    try {
      const { error: updateError } = await supabase.auth.updateUser({ password });
      if (updateError) throw updateError;
      // Activates the owner's membership so their business's data becomes visible.
      const { error: acceptError } = await supabase.rpc("zella_accept_my_invitations");
      if (acceptError) console.error("Accepting invitation failed", acceptError);
      // A platform admin who reset their password goes back to the admin dashboard.
      let isAdmin = false;
      try { isAdmin = (await supabase.rpc("is_platform_admin"))?.data === true; } catch { /* go to the CRM */ }
      window.location.replace(isAdmin ? "/" : "/app");
    } catch (err) {
      setError(err.message);
      setBusy(false);
    }
  }

  if (state === "checking") {
    return <AuthCard title="One moment..." description="Checking your link." />;
  }

  if (state === "invalid") {
    return (
      <AuthCard
        eyebrow="LINK EXPIRED"
        title="This link no longer works"
        description={`${linkError ? `${linkError}. ` : ""}Links can only be used once and expire after a while. Ask the Zella team to resend your invitation, or reset your password from the sign-in page.`}
      >
        <a className="ba-btn primary block" href="/app">Go to sign in</a>
      </AuthCard>
    );
  }

  return (
    <AuthCard
      eyebrow="WELCOME TO ZELLA"
      title="Set your password"
      description={email ? `You'll use ${email} and this password to sign in.` : "Choose a password to finish setting up your account."}
    >
      <form className="ba-form" onSubmit={save}>
        <div className="ba-field">
          <span>New password</span>
          <PasswordField value={password} onChange={setPassword} />
        </div>
        <div className="ba-field">
          <span>Confirm password</span>
          <ConfirmPasswordField value={confirm} password={password} onChange={setConfirm} />
        </div>
        {error && <div className="ba-error">{error}</div>}
        <button type="submit" className="ba-btn primary block" disabled={busy}>
          {busy ? "Saving..." : "Save password and continue"}
        </button>
      </form>
    </AuthCard>
  );
}
