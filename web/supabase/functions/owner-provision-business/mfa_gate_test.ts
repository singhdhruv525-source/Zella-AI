// deno test --no-lock web/supabase/functions/owner-provision-business/mfa_gate_test.ts   (no network)
import { assertEquals } from "jsr:@std/assert@1";
import { mfaGate, tokenAal } from "./mfa_gate.ts";

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
