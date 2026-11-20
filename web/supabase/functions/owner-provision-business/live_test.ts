import { assertEquals } from "jsr:@std/assert@1";
import { type LiveBusiness, liveFor, savedStatus, startOnSave } from "./live.ts";

const B = {
  draft: { onboarding_status: "automation_setup", is_active: false, suspended_at: null, cancelled_at: null },
  testing: { onboarding_status: "testing", is_active: true, suspended_at: null, cancelled_at: null },
  live: { onboarding_status: "active", is_active: true, suspended_at: null, cancelled_at: null },
  suspended: { onboarding_status: "active", is_active: false, suspended_at: "2026-11-16T10:00:00Z", cancelled_at: null },
  suspendedDraft: { onboarding_status: "testing", is_active: false, suspended_at: "2026-11-16T10:00:00Z", cancelled_at: null },
  cancelled: { onboarding_status: "active", is_active: false, suspended_at: null, cancelled_at: "2026-11-01T00:00:00Z" },
};

Deno.test("liveFor: only a business that went live and is neither suspended nor cancelled", () => {
  assertEquals(Object.fromEntries(Object.entries(B).map(([k, b]) => [k, liveFor(b)])),
    { draft: false, testing: false, live: true, suspended: false, suspendedDraft: false, cancelled: false });
});

Deno.test("the switch is off unless set to on", () => {
  for (const v of [undefined, null, "", "off", "true", "1"]) assertEquals(startOnSave(v), false, String(v));
  for (const v of ["on", " ON "]) assertEquals(startOnSave(v), true, v);
});

Deno.test("switch off: every save behaves exactly as before", () => {
  for (const [name, business] of Object.entries(B)) {
    for (const current of [null, "paused", "active", "disabled"]) {
      assertEquals(savedStatus({ kind: "standard", enabled: true, current, business, switchOn: false }),
        { status: current === "active" ? "active" : "paused", pausedBySuspension: false }, `${name} ${current}`);
      assertEquals(savedStatus({ kind: "rule", enabled: true, current, business, switchOn: false }),
        { status: business.is_active ? "active" : "paused", pausedBySuspension: false }, `rule ${name}`);
      assertEquals(savedStatus({ kind: "standard", enabled: false, current, business, switchOn: false }).status, "disabled");
    }
  }
});

Deno.test("switch on: the status matrix (BIZ-07)", () => {
  const on = (business: LiveBusiness, kind: "standard" | "rule" = "standard", current: string | null = "paused") =>
    savedStatus({ kind, enabled: true, current, business, switchOn: true });
  assertEquals(on(B.live), { status: "active", pausedBySuspension: false });              // starts at once
  assertEquals(on(B.live, "rule"), { status: "active", pausedBySuspension: false });
  assertEquals(on(B.testing), { status: "paused", pausedBySuspension: false });           // waits for go live
  assertEquals(on(B.testing, "rule"), { status: "paused", pausedBySuspension: false });   // was active before
  assertEquals(on(B.testing, "standard", "active"), { status: "paused", pausedBySuspension: false });
  assertEquals(on(B.draft), { status: "paused", pausedBySuspension: false });
  assertEquals(on(B.suspended), { status: "paused", pausedBySuspension: true });          // restarts on reactivation
  assertEquals(on(B.suspendedDraft), { status: "paused", pausedBySuspension: false });
  assertEquals(on(B.cancelled), { status: "paused", pausedBySuspension: false });
  assertEquals(savedStatus({ kind: "rule", enabled: false, current: "active", business: B.live, switchOn: true }), { status: "disabled", pausedBySuspension: false });
});
