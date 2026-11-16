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

// The aal claim of the caller's access token; anything unreadable counts as aal1 (fails closed).
export function tokenAal(authorization: string): string {
  try {
    const payload = authorization.slice(7).split(".")[1].replace(/-/g, "+").replace(/_/g, "/");
    return String(JSON.parse(atob(payload.padEnd(Math.ceil(payload.length / 4) * 4, "="))).aal ?? "aal1");
  } catch {
    return "aal1";
  }
}
