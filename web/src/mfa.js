import { useCallback, useEffect, useState } from "react";
import { supabase } from "./supabase";

// Two-step sign-in with an authenticator app (Supabase Auth TOTP factors).
// After the password, people who set it up must enter a 6-digit code before
// the app opens. The admin server function also refuses requests without it.

// "ok" | "needs_code" | "checking"
export function useMfaGate(session) {
  const [state, setState] = useState("checking");
  const check = useCallback(async () => {
    if (!session) { setState("ok"); return; }
    setState("checking");
    const { data, error } = await supabase.auth.mfa.getAuthenticatorAssuranceLevel();
    if (error) { setState("ok"); return; }
    setState(data.nextLevel === "aal2" && data.currentLevel !== "aal2" ? "needs_code" : "ok");
  }, [session]);
  useEffect(() => { check(); }, [check]);
  return { state, recheck: check };
}

export async function verifyMfaCode(code) {
  const clean = String(code ?? "").replace(/\s/g, "");
  if (!/^\d{6}$/.test(clean)) throw new Error("Enter the 6-digit code from your authenticator app.");
  const { data, error } = await supabase.auth.mfa.listFactors();
  if (error) throw error;
  const factor = (data?.totp ?? []).find((f) => f.status === "verified");
  if (!factor) throw new Error("No authenticator app is set up for this account.");
  const { error: verifyError } = await supabase.auth.mfa.challengeAndVerify({ factorId: factor.id, code: clean });
  if (verifyError) throw new Error(/invalid|expired/i.test(verifyError.message) ? "That code didn't work. Codes change every 30 seconds; try the newest one." : verifyError.message);
}

export async function mfaStatus() {
  const { data, error } = await supabase.auth.mfa.listFactors();
  if (error) throw error;
  const verified = (data?.totp ?? []).filter((f) => f.status === "verified");
  const { data: level } = await supabase.auth.mfa.getAuthenticatorAssuranceLevel();
  return { enrolled: verified.length > 0, factors: verified, level: level?.currentLevel ?? "aal1" };
}

// Starts setting up an authenticator app; returns the QR code (SVG data URL) and the secret to type in by hand.
export async function startMfaEnrollment() {
  // Remove any half-finished set-up first, so a retry works.
  const { data } = await supabase.auth.mfa.listFactors();
  for (const f of data?.all ?? []) if (f.status !== "verified") await supabase.auth.mfa.unenroll({ factorId: f.id });
  const { data: enrolled, error } = await supabase.auth.mfa.enroll({ factorType: "totp", friendlyName: `Authenticator ${new Date().toISOString().slice(0, 10)}` });
  if (error) throw new Error(/disabled|not enabled/i.test(error.message) ? "Two-step sign-in isn't switched on for this Zella project yet (Supabase, Authentication, Multi-factor)." : error.message);
  return { factorId: enrolled.id, qr: enrolled.totp.qr_code, secret: enrolled.totp.secret };
}

export async function finishMfaEnrollment(factorId, code) {
  const clean = String(code ?? "").replace(/\s/g, "");
  if (!/^\d{6}$/.test(clean)) throw new Error("Enter the 6-digit code from your authenticator app.");
  const { error } = await supabase.auth.mfa.challengeAndVerify({ factorId, code: clean });
  if (error) throw new Error(/invalid|expired/i.test(error.message) ? "That code didn't work. Try the newest one." : error.message);
}

export async function removeMfaFactor(factorId) {
  const { error } = await supabase.auth.mfa.unenroll({ factorId });
  if (error) throw new Error(/aal2/i.test(error.message) ? "Sign in with your code first, then remove it." : error.message);
}
