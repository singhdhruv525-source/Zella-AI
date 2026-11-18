import { useCallback, useEffect, useState } from "react";
import { supabase } from "./supabase";

// Two-step sign-in with an authenticator app (Supabase Auth TOTP factors).
// After the password, people who set it up must enter a 6-digit code before
// the app opens. The admin server function also refuses requests without it.

// "ok" | "needs_code" | "checking" | "error"
export function useMfaGate(session) {
  const [state, setState] = useState("checking");
  const check = useCallback(async () => {
    if (!session) { setState("ok"); return; }
    setState("checking");
    try {
      const { data, error } = await supabase.auth.mfa.getAuthenticatorAssuranceLevel();
      if (error || !data || !["aal1", "aal2"].includes(data.currentLevel) || !["aal1", "aal2"].includes(data.nextLevel)) { setState("error"); return; }
      setState(data.nextLevel === "aal2" && data.currentLevel !== "aal2" ? "needs_code" : "ok");
    } catch {
      setState("error");
    }
  }, [session]);
  useEffect(() => { check(); }, [check]);
  return { state, recheck: check };
}

// Checks a code against the given authenticator, or, when none is given, against each of the person's verified
// authenticators in turn, so a code from any of their apps works (not only the first one set up).
export async function verifyMfaCode(code, factorId = null) {
  const clean = String(code ?? "").replace(/\s/g, "");
  if (!/^\d{6}$/.test(clean)) throw new Error("Enter the 6-digit code from your authenticator app.");
  const { data, error } = await supabase.auth.mfa.listFactors();
  if (error) throw error;
  const verified = (data?.totp ?? []).filter((f) => f.status === "verified" && (!factorId || f.id === factorId));
  if (!verified.length) throw new Error(factorId ? "That authenticator app isn't set up for this account." : "No authenticator app is set up for this account.");
  let lastError = null;
  for (const factor of verified) {
    const { error: verifyError } = await supabase.auth.mfa.challengeAndVerify({ factorId: factor.id, code: clean });
    if (!verifyError) return;
    lastError = verifyError;
    if (!/invalid|expired/i.test(verifyError.message)) break;   // only a wrong code tries the next app
  }
  throw new Error(/invalid|expired/i.test(lastError.message) ? "That code didn't work. Codes change every 30 seconds; try the newest one." : lastError.message);
}

export async function mfaStatus() {
  await recordPendingMfaAdded();
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
  const { data: enrolled, error } = await supabase.auth.mfa.enroll({ factorType: "totp", friendlyName: `Authenticator ${new Date().toISOString().slice(0, 19).replace("T", " ")}` });   // unique per person: Supabase refuses two with the same name
  if (error) throw new Error(/disabled|not enabled/i.test(error.message) ? "Two step sign in isn't switched on for this Zella Voice project yet (Supabase, Authentication, multi factor)." : error.message);
  return { factorId: enrolled.id, qr: enrolled.totp.qr_code, secret: enrolled.totp.secret };
}

export async function finishMfaEnrollment(factorId, code) {
  const clean = String(code ?? "").replace(/\s/g, "");
  if (!/^\d{6}$/.test(clean)) throw new Error("Enter the 6-digit code from your authenticator app.");
  // the account setting it up and whether it is an admin, known before the code is checked; an admin's authenticator
  // is put on the retry list first, so even a lost answer to the check below leaves it to be recorded
  const owner = await currentUserId().catch(() => null);
  if (!owner) throw new Error("Your account couldn't be checked, so the authenticator wasn't turned on. Try again.");
  // (an admin who hasn't verified a code yet may be refused this read: then it is listed as possibly an admin)
  const { data: role, error: roleError } = await supabase.rpc("zella_admin_role").then((r) => r, (e) => ({ error: e }));
  const admin = roleError ? null : Boolean(role);
  if (admin !== false) keepPending(owner, factorId, admin);
  const { error } = await supabase.auth.mfa.challengeAndVerify({ factorId, code: clean });
  if (error) {
    // A refused code turned nothing on, but an earlier attempt that ended without a clear answer may have: the id is
    // dropped only when no attempt for it may have turned it on. Any other failure is remembered as such an attempt.
    if (!/invalid|expired/i.test(error.message)) markMaybeOn(owner, factorId);
    else if (!pending().some((p) => p.factorId === factorId && p.userId === owner && p.maybeOn)) dropPending(owner, factorId);
    throw new Error(/invalid|expired/i.test(error.message) ? "That code didn't work. Try the newest one." : error.message);
  }
  if (admin !== false) await recordAdminMfaAdded(factorId, owner);
}

// ACC-30: a platform admin's own security changes go through owner-provision-business, which audits them. Errors
// keep the server's code (FRESH_CODE_REQUIRED, ...).
async function adminAction(action, payload = {}) {
  const { data, error } = await supabase.functions.invoke("owner-provision-business", { body: { action, ...payload } });
  if (error) {
    let body = {};
    try { body = (await error.context?.json()) ?? {}; } catch { /* keep the default message */ }
    throw Object.assign(new Error(body.error || "That didn't work. Try again."), { code: body.code, status: error.context?.status });
  }
  return data;
}

// An admin's new authenticator is recorded in the audit log (admin.mfa_added). With sql/zella_admin_sessions.sql the
// database writes it the moment the authenticator is verified, with the role at that moment; the browser's call
// below then finds it already there. Until then (and as a check) the browser asks the server, which records it once
// per authenticator and answers 503 when it can't. The authenticator is already on, so a failure never asks for a new
// set up: the factor id stays in this browser's list, put there before the code is checked, and is recorded the next
// time the security settings load (mfaStatus), until the server confirms it. Each listed id belongs to the account
// that set it up while it was an admin: only that account's own ids are tried, another account's stay for it, and an
// id stays listed when the account changes during a try, or when it is no longer an admin (the server would refuse it).
// Business members are not admins, so nothing is listed or sent for them.
const PENDING_KEY = "zella-admin-mfa-added-pending";
const pending = () => {
  try { return JSON.parse(localStorage.getItem(PENDING_KEY) ?? "[]").filter((x) => x && typeof x.userId === "string" && typeof x.factorId === "string"); }
  catch { return []; }
};
const savePending = (list) => { try { if (list.length) localStorage.setItem(PENDING_KEY, JSON.stringify(list)); else localStorage.removeItem(PENDING_KEY); } catch { /* storage off */ } };
// admin: true when the account was an admin when it set the authenticator up, null when that couldn't be read
const keepPending = (userId, factorId, admin = true) => { if (!pending().some((p) => p.factorId === factorId && p.userId === userId)) savePending([...pending(), { userId, factorId, admin }]); };
const markMaybeOn = (userId, factorId) => savePending(pending().map((p) => (p.factorId === factorId && p.userId === userId ? { ...p, maybeOn: true } : p)));
const dropPending = (userId, factorId) => savePending(pending().filter((p) => !(p.factorId === factorId && p.userId === userId)));
const currentUserId = async () => (await supabase.auth.getUser())?.data?.user?.id ?? null;
// The id leaves the list only when the server's answer names it (a failed audit write answers 503), read while the
// same account is signed in.
async function recordAdminMfaAdded(factorId, owner) {
  const sameAccount = async () => owner && (await currentUserId().catch(() => null)) === owner;
  try {
    if (!(await sameAccount())) throw new Error("another account is signed in now");
    const { data: role, error } = await supabase.rpc("zella_admin_role");
    if (error) throw error;
    if (!role) {
      // known to have been an admin then: it stays listed. Not known: this account isn't an admin, so nothing to record.
      if (pending().some((p) => p.factorId === factorId && p.userId === owner && p.admin === true)) throw new Error("not an admin now; the entry stays listed");
      dropPending(owner, factorId);
      return true;
    }
    const done = await adminAction("me_mfa_added", { factorId });
    if (done?.factorId !== factorId) throw new Error("the server did not confirm the entry");
    if (!(await sameAccount())) throw new Error("another account signed in meanwhile");
    dropPending(owner, factorId);
    return true;
  } catch (err) {
    console.warn("Recording the new authenticator failed; it is tried again later", err?.message);
    if (owner && !pending().some((p) => p.factorId === factorId && p.userId === owner)) keepPending(owner, factorId);
    return false;
  }
}
async function recordPendingMfaAdded() {
  const me = await currentUserId().catch(() => null);
  if (!me) return;
  // every one of this account's ids is tried, even when an earlier one fails again
  for (const p of pending().filter((x) => x.userId === me)) await recordAdminMfaAdded(p.factorId, me);
}

// Business members remove an authenticator straight with Supabase Auth. Admins go through the server, with a new
// code: it refuses their last authenticator (ACC-01) and audits the removal (admin.mfa_removed). Whether this is an
// admin is checked here too, so an admin is never sent down the direct path; if that can't be checked, nothing is
// removed.
export async function removeMfaFactor(factorId, { admin = false, code } = {}) {
  let isAdmin = admin;
  if (!isAdmin) {
    const { data: role, error } = await supabase.rpc("zella_admin_role");
    if (error) throw new Error("Your account couldn't be checked, so nothing was removed. Try again.");
    isAdmin = Boolean(role);
  }
  if (isAdmin) {
    await verifyMfaCode(code);
    await adminAction("me_mfa_remove", { factorId });
    return;
  }
  const { error } = await supabase.auth.mfa.unenroll({ factorId });
  if (error) throw new Error(/aal2/i.test(error.message) ? "Sign in with your code first, then remove it." : error.message);
}

// Admins change their password through the server after a new code (audited as admin.password_changed);
// business members keep Supabase Auth's own flow.
export async function changeAdminPassword(password, code) {
  await verifyMfaCode(code);
  await adminAction("me_password_change", { password });
}
