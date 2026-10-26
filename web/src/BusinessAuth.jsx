import { useEffect, useState } from "react";
import "./BusinessApp.css";
import { supabase } from "./supabase";
import { ConfirmPasswordField, EmailField, PasswordField } from "./formFields";
import { checkEmail, passwordProblems } from "./formValidation";
import { EMAIL_LINK_TYPES, friendlyAuthError, readEmailLink } from "./authErrors";
import { verifyMfaCode } from "./mfa";
import { maintenanceText, usePlatformInfo } from "./platformInfo";

// Sign-in, forgotten password and the welcome (set password) page for
// business owners and staff. Platform admins use the admin sign-in at "/".
// Joins every business that invited this account: owners set up by the Zella team
// (zella_accept_my_invitations) and team members invited from Team access
// (zella_accept_staff_invitations). Both are safe to repeat. A failure here never
// blocks sign-in; the workspace list simply stays as it was.
export async function acceptInvitations() {
  const results = await Promise.all([
    supabase.rpc("zella_accept_my_invitations"),
    supabase.rpc("zella_accept_staff_invitations"),
  ]);
  for (const { error } of results) if (error) console.error("Accepting invitations failed:", error.message);
}

function AuthCard({ eyebrow, title, description, children }) {
  const platform = usePlatformInfo();
  return (
    <main className="ba-auth">
        <section className="ba-auth-card">
          <div className="ba-brand">
            {platform.logo_url ? <img src={platform.logo_url} alt="" style={{ maxHeight: 36 }} /> : <div className="ba-logo">Z</div>}
            <div>
              <div className="ba-brand-name">{platform.display_name ?? "Zella AI"}</div>
              <div className="ba-brand-sub">{platform.login_headline || "Hands full. Phone handled."}</div>
            </div>
          </div>
          {maintenanceText(platform) && <div className="ba-banner" role="status"><span>{maintenanceText(platform)}</span></div>}
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

// Second step for people who set up an authenticator app.
export function MfaCodeCard({ email, onDone }) {
  const [code, setCode] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  async function submit(event) {
    event.preventDefault();
    setBusy(true);
    setError("");
    try {
      await verifyMfaCode(code);
      await onDone();
    } catch (err) {
      setError(friendlyAuthError(err));
      setBusy(false);
    }
  }
  return (
    <AuthCard title="Enter your code" description={`Open your authenticator app and enter the 6-digit code for ${email || "your account"}.`}>
      <form className="ba-form" onSubmit={submit}>
        <label className="ba-field">
          <span>Authenticator code</span>
          <input inputMode="numeric" autoComplete="one-time-code" maxLength={7} value={code} onChange={(e) => setCode(e.target.value)} autoFocus required />
        </label>
        {error && <div className="ba-error">{error}</div>}
        <button type="submit" className="ba-btn primary block" disabled={busy}>{busy ? "Checking..." : "Verify and continue"}</button>
        <button type="button" className="ba-link ba-center" onClick={() => supabase.auth.signOut()}>Use a different account</button>
      </form>
    </AuthCard>
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
      setError(friendlyAuthError(err));
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
      setNotice("Check your email. If an account exists for that address, the link is on its way. Open the newest email only, once.");
    } catch (err) {
      setError(friendlyAuthError(err));
    } finally {
      setBusy(false);
    }
  }

  if (mode === "reset") {
    return (
      <AuthCard
        title="Reset your password"
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
    <AuthCard title="Welcome back." description="See what Zella handled while you were busy.">
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

  const [link] = useState(() => readEmailLink());

  useEffect(() => {
    // Expired or already-used links come back with an error in the URL.
    if (link.error) {
      setLinkError(link.error);
      setState("invalid");
      return;
    }
    // The safer link: nothing is used up until the person presses Continue.
    if (link.tokenHash && EMAIL_LINK_TYPES.includes(link.type)) {
      setState("confirm");
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
  }, [link]);

  async function confirmLink() {
    setBusy(true);
    setError("");
    try {
      const { data, error: verifyError } = await supabase.auth.verifyOtp({ token_hash: link.tokenHash, type: link.type });
      if (verifyError) throw verifyError;
      // Keep the address bar clean so a refresh doesn't try the used link again.
      window.history.replaceState(null, "", window.location.pathname);
      // Confirming an email address (sign-up, magic link, email change) needs no new password.
      if (!["invite", "recovery"].includes(link.type)) {
        await acceptInvitations();
        window.location.replace("/app");
        return;
      }
      setEmail(data?.user?.email ?? data?.session?.user?.email ?? "");
      setState("ready");
    } catch (err) {
      setLinkError(friendlyAuthError(err));
      setState("invalid");
    } finally {
      setBusy(false);
    }
  }

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
      // Activates the person's memberships so their business's data becomes visible.
      await acceptInvitations();
      // A platform admin who reset their password goes back to the admin dashboard.
      let isAdmin = false;
      try { isAdmin = (await supabase.rpc("is_platform_admin"))?.data === true; } catch { /* go to the CRM */ }
      window.location.replace(isAdmin ? "/" : "/app");
    } catch (err) {
      setError(friendlyAuthError(err));
      setBusy(false);
    }
  }

  if (state === "checking") {
    return <AuthCard title="One moment..." description="Checking your link." />;
  }

  if (state === "confirm") {
    const resetting = link.type === "recovery";
    return (
      <AuthCard
        title={resetting ? "Reset your password" : "Welcome to Zella"}
        description={resetting
          ? "Press continue to choose a new password."
          : link.type === "invite"
            ? "Press continue to accept your invitation and choose a password."
            : "Press continue to confirm your email address."}
      >
        {error && <div className="ba-error">{error}</div>}
        <button type="button" className="ba-btn primary block" onClick={confirmLink} disabled={busy}>
          {busy ? "Checking your link..." : "Continue"}
        </button>
      </AuthCard>
    );
  }

  if (state === "invalid") {
    return (
      <AuthCard
        title="This link can't be used"
        description={`${linkError ? `${linkError.replace(/\.$/, "")}. ` : ""}Ask the person who invited you to send a new invitation, or reset your password from the sign-in page.`}
      >
        <a className="ba-btn primary block" href="/app">Business sign in</a>
        <a className="ba-link ba-center" href="/">Zella admin sign in</a>
      </AuthCard>
    );
  }

  return (
    <AuthCard
      title="Set up your front desk"
      description={email ? `You'll use ${email} and this password to sign in.` : "Choose a password and you are ready to go."}
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
