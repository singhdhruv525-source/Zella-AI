// deno test --no-lock web/supabase/functions/owner-provision-business/mfa_gate_test.ts   (no network)
import { assertEquals } from "jsr:@std/assert@1";
import { codeEnteredAt, FRESH_CODE_ACTIONS, freshCode, freshCodeGate, mfaGate, tokenAal } from "./mfa_gate.ts";

Deno.test("an admin with an authenticator must have used it this session", () => {
  assertEquals(mfaGate({ hasVerifiedFactor: true, aal: "aal2", action: "dashboard_data" }), { ok: true, setupRequired: false });
  const r = mfaGate({ hasVerifiedFactor: true, aal: "aal1", action: "dashboard_data" });
  assertEquals([r.ok, !r.ok && r.code], [false, "MFA_REQUIRED"]);
  // reading their own role needs the code too once it's set up
  assertEquals(mfaGate({ hasVerifiedFactor: true, aal: "aal1", action: "me_admin" }).ok, false);
});

Deno.test("an admin without one may only read their own role, to be sent to set up", () => {
  assertEquals(mfaGate({ hasVerifiedFactor: false, aal: "aal1", action: "me_admin" }), { ok: true, setupRequired: true });
  for (const action of ["dashboard_data", "setup_finish", "admin_invite", "business_suspend", "audit_logs", ""]) {
    const r = mfaGate({ hasVerifiedFactor: false, aal: "aal1", action });
    assertEquals([r.ok, !r.ok && r.code, !r.ok && r.status], [false, "MFA_SETUP_REQUIRED", 403], action);
  }
  // a claimed aal2 without any factor still can't do anything else
  assertEquals(mfaGate({ hasVerifiedFactor: false, aal: "aal2", action: "dashboard_data" }).ok, false);
});

Deno.test("the token's aal; anything unreadable is aal1", () => {
  const tok = (claims: unknown) => "Bearer x." + btoa(JSON.stringify(claims)).replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_") + ".y";
  assertEquals(tokenAal(tok({ aal: "aal2" })), "aal2");
  assertEquals(tokenAal(tok({ sub: "u" })), "aal1");
  assertEquals(tokenAal("Bearer garbage"), "aal1");
});

const bearer = (claims: unknown) => "Bearer x." + btoa(JSON.stringify(claims)).replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_") + ".y";
const NOW = 1_800_000_000;

Deno.test("fresh code: the newest authenticator time in amr, within 5 minutes", () => {
  const amr = (...entries: unknown[]) => bearer({ aal: "aal2", amr: entries });
  assertEquals(codeEnteredAt(amr({ method: "password", timestamp: NOW }, { method: "totp", timestamp: NOW - 100 }, { method: "totp", timestamp: NOW - 50 })), NOW - 50);
  assertEquals(freshCode(amr({ method: "totp", timestamp: NOW - 299 }), NOW), true);
  assertEquals(freshCode(amr({ method: "totp", timestamp: NOW - 300 }), NOW), true);
  assertEquals(freshCode(amr({ method: "totp", timestamp: NOW - 301 }), NOW), false);      // older than 5 minutes
});

Deno.test("fresh code fails closed", () => {
  for (const claims of [
    { aal: "aal2" },                                                   // no amr
    { aal: "aal2", amr: "totp" },                                      // not a list
    { aal: "aal2", amr: [{ method: "password", timestamp: NOW }] },    // a password is not a code
    { aal: "aal2", amr: [{ method: "totp" }] },                        // no time
    { aal: "aal2", amr: [{ method: "totp", timestamp: "soon" }] },     // not a number
    { aal: "aal2", amr: [{ method: "totp", timestamp: NOW + 120 }] },  // in the future
    { aal: "aal2", amr: [null, 3] },
  ]) assertEquals(freshCode(bearer(claims), NOW), false, JSON.stringify(claims));
  assertEquals(freshCode("Bearer garbage", NOW), false);
  assertEquals(freshCode("", NOW), false);
});

Deno.test("only granting or changing admin access needs the fresh code", () => {
  const stale = bearer({ aal: "aal2", amr: [{ method: "totp", timestamp: NOW - 3600 }] });
  const fresh = bearer({ aal: "aal2", amr: [{ method: "totp", timestamp: NOW - 10 }] });
  for (const action of FRESH_CODE_ACTIONS) {
    assertEquals(freshCodeGate(action, stale, NOW), { ok: false, status: 403, code: "FRESH_CODE_REQUIRED", error: "For this change, enter a new code from your authenticator app." });
    assertEquals(freshCodeGate(action, fresh, NOW), { ok: true });
  }
  assertEquals(FRESH_CODE_ACTIONS, ["admin_invite", "admin_update", "me_mfa_remove", "me_password_change"]);
  for (const action of ["admins_list", "dashboard_data", "me_admin", "roles_get", "me_mfa_added"]) assertEquals(freshCodeGate(action, stale, NOW), { ok: true });
});
