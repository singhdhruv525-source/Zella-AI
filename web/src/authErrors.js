import { LANDING_URL } from "./supabase";

// Plain-language versions of the errors Supabase sign-in returns.
export function friendlyAuthError(error) {
  const message = String(error?.message ?? error ?? "");
  if (/invalid login|invalid credentials/i.test(message)) {
    return "That email or password doesn't match. Try again, or reset your password.";
  }
  if (/email not confirmed/i.test(message)) {
    return "This email hasn't been confirmed yet. Open the link in your invitation email first, or use Forgot your password to get a new link.";
  }
  if (/rate limit|too many|only request this after|security purposes/i.test(message)) {
    return "Too many emails were sent to this address in a short time. Wait a minute and try again.";
  }
  if (/same password|different from the old/i.test(message)) {
    return "Choose a password you haven't used here before.";
  }
  if (/weak|pwned|leaked|known to be/i.test(message)) {
    return "That password has appeared in a data breach. Choose a different one.";
  }
  if (/expired|invalid.*(token|otp|link)|token.*(not found|expired)/i.test(message)) {
    return "This link has expired or was already used. Ask for a new one, or use Forgot your password.";
  }
  if (/fetch|network|failed to load/i.test(message)) {
    return "Couldn't reach Zella. Check your internet connection and try again.";
  }
  return message || "Something went wrong. Please try again.";
}

// What an email link brought the person here with. Supabase links arrive in two
// shapes: the older "#access_token=...&type=invite" (or "#error_code=..."), and the
// safer "?token_hash=...&type=invite", which is only used when the person presses
// a button, so mail scanners that open links can't use it up first.
export function readEmailLink() {
  const hash = new URLSearchParams((LANDING_URL.hash || window.location.hash || "").replace(/^#/, ""));
  const query = new URLSearchParams(LANDING_URL.search || window.location.search || "");
  const pick = (key) => hash.get(key) ?? query.get(key);
  const code = pick("error_code");
  const description = pick("error_description");
  return {
    tokenHash: query.get("token_hash"),
    type: pick("type"),
    error: code || description
      ? code === "otp_expired"
        ? "This link has expired or was already used. Email links work only once, and some mail apps open links early to scan them."
        : (description || "This link could not be used.").replace(/\+/g, " ")
      : "",
  };
}

export const EMAIL_LINK_TYPES = ["invite", "recovery", "signup", "magiclink", "email", "email_change"];
