// Two step sign in for platform admins (REQ-LC-04, ARCHITECTURE "MFA required for platform staff"; audit ACC-01).
// Every active admin must have a verified authenticator and have used it for this session. An admin who hasn't set
// one up yet may only read their own role (me_admin), so the app can walk them through setting it up; every other
// action is refused until then. Pure: tested in mfa_gate_test.ts.

export type MfaGate =
  | { ok: true; setupRequired: boolean }
  | { ok: false; status: 403; code: "MFA_REQUIRED" | "MFA_SETUP_REQUIRED"; error: string };

export const MFA_SETUP_MESSAGE =
  "Set up two step sign in to continue. Every Zella Voice admin needs an authenticator app.";
export const MFA_CODE_MESSAGE = "Enter the code from your authenticator app to continue.";

export function mfaGate(input: { hasVerifiedFactor: boolean; aal: string; action: string }): MfaGate {
  if (input.hasVerifiedFactor) {
    return input.aal === "aal2"
      ? { ok: true, setupRequired: false }
      : { ok: false, status: 403, code: "MFA_REQUIRED", error: MFA_CODE_MESSAGE };
  }
  if (input.action === "me_admin") return { ok: true, setupRequired: true };
  return { ok: false, status: 403, code: "MFA_SETUP_REQUIRED", error: MFA_SETUP_MESSAGE };
}

// The claims of the caller's access token (already checked by Supabase Auth in index.ts); {} when unreadable.
function tokenClaims(authorization: string): Record<string, unknown> {
  try {
    const payload = authorization.slice(7).split(".")[1].replace(/-/g, "+").replace(/_/g, "/");
    const claims = JSON.parse(atob(payload.padEnd(Math.ceil(payload.length / 4) * 4, "=")));
    return claims && typeof claims === "object" ? claims : {};
  } catch {
    return {};
  }
}

// The aal claim of the caller's access token; anything unreadable counts as aal1 (fails closed).
export function tokenAal(authorization: string): string {
  return String(tokenClaims(authorization).aal ?? "aal1");
}

// ACC-19: granting or changing admin access needs an authenticator code entered in the last few minutes, not just a
// session that was verified once (it can be hours old). Supabase Auth records when the code was entered in the
// token's amr claim ({ method: "totp", timestamp }); verifying a code again issues a token with a new timestamp.
// Owner decision taken as the recommended default: a fresh code only, no second owner approval.
export const FRESH_CODE_MAX_AGE_SECONDS = 300;
export const FRESH_CODE_ACTIONS = ["admin_invite", "admin_update"];
export const FRESH_CODE_MESSAGE = "For this change, enter a new code from your authenticator app.";

// When the caller last entered an authenticator code (seconds since 1970), or null.
export function codeEnteredAt(authorization: string): number | null {
  const amr = tokenClaims(authorization).amr;
  if (!Array.isArray(amr)) return null;
  const times = amr
    .filter((m) => m && typeof m === "object" && (m as { method?: unknown }).method === "totp")
    .map((m) => Number((m as { timestamp?: unknown }).timestamp))
    .filter((t) => Number.isFinite(t) && t > 0);
  return times.length ? Math.max(...times) : null;
}

// Fails closed: no code time, a code older than the limit, or one dated in the future (beyond a minute of clock skew).
export function freshCode(authorization: string, nowSeconds = Math.floor(Date.now() / 1000), maxAge = FRESH_CODE_MAX_AGE_SECONDS): boolean {
  const at = codeEnteredAt(authorization);
  return at !== null && at <= nowSeconds + 60 && nowSeconds - at <= maxAge;
}

export function freshCodeGate(action: string, authorization: string, nowSeconds = Math.floor(Date.now() / 1000)) {
  if (!FRESH_CODE_ACTIONS.includes(action) || freshCode(authorization, nowSeconds)) return { ok: true as const };
  return { ok: false as const, status: 403 as const, code: "FRESH_CODE_REQUIRED" as const, error: FRESH_CODE_MESSAGE };
}
