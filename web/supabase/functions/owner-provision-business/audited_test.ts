// BIZ-17: every setup and lifecycle audit row records before and after, never full emails or phone numbers, and the
// before values never reach the browser. A failed audit write raises an alert.
import { assert, assertEquals, assertFalse } from "jsr:@std/assert@1";
import type { SupabaseClient } from "@supabase/supabase-js";
import { withBefore } from "./detail.ts";

// index.ts starts the server when it is imported; here it must not.
(Deno as unknown as { serve: unknown }).serve = () => ({ finished: Promise.resolve(), shutdown: () => Promise.resolve() });
const { AUDITED, AUDIT_WARNING, writeAudit } = await import("./index.ts");

const BIZ = "3e000000-0000-0000-0000-00000000b000";
const life = (o: Record<string, unknown>) => ({ is_active: true, onboarding_status: "active", suspended_at: null, cancel_at: null, cancelled_at: null, ...o });

// [action, request fields, handler result with its before values]
const CASES: [string, Record<string, unknown>, Record<string, unknown>][] = [
  ["setup_save_business", {}, withBefore({ businessId: BIZ, created: false, industryChanged: false,
    values: { name: "New name", email: "front@shop.example", phone: "+15550100100", city: "Austin", timezone: "America/Chicago" } },
    { name: "Old name", email: "old@shop.example", phone: "+15550100199", city: "Austin", timezone: "America/New_York" })],
  ["setup_save_owner", { owner: { name: "Ola Owner", email: "ola@people.example" } }, withBefore({ businessId: BIZ }, { email: "old@people.example", status: "pending" })],
  ["setup_save_terminology", { overrides: { customer: "client" } }, withBefore({ businessId: BIZ }, { overrides: { customer: "patient" } })],
  ["setup_save_modules", { enabledModuleIds: ["3e000000-0000-0000-0000-0000000000c1"] }, withBefore({ businessId: BIZ, enabledModules: 1 }, { enabled_module_ids: [] })],
  ["setup_save_receptionist", { receptionist: { personality: "warm" } }, withBefore({ businessId: BIZ, services: 3, faqs: 2, configHash: "b2" }, { services: 1, faqs: 2, personality: "friendly", config_hash: "a1" })],
  ["setup_save_integrations", { integrations: { phone: { mode: "new_number" }, calendar: "google", email: "gmail", leadSources: {} } },
    withBefore({ businessId: BIZ }, { phone_mode: "call_forwarding", calendar: null, email: null, lead_sources: null })],
  ["setup_save_automations", { automations: { appointment_reminder: { enabled: true } } }, withBefore({ businessId: BIZ }, { enabled: [] })],
  ["business_suspend", {}, withBefore({ businessId: BIZ, reason: "Payment problem", after: life({ suspended_at: "2026-11-16T10:00:00Z", is_active: false }) }, life({}))],
  ["business_reactivate", {}, withBefore({ businessId: BIZ, after: life({}) }, life({ suspended_at: "2026-11-16T10:00:00Z" }))],
  ["business_cancel", {}, withBefore({ businessId: BIZ, cancelAt: "2026-12-01T00:00:00Z", reason: "", emailSent: true, emailError: null }, { cancel_at: null, cancellation_reason: null })],
  ["business_undo_cancel", {}, withBefore({ businessId: BIZ, previousCancelAt: "2026-12-01T00:00:00Z" }, { cancel_at: "2026-12-01T00:00:00Z", cancellation_reason: "Moving" })],
  ["invitation_resend", {}, withBefore({ businessId: BIZ, email: "ola@people.example", invitationStatus: "failed", invitationError: "Mailbox ola@people.example is full" }, { status: "sent" })],
  ["setup_finish", {}, withBefore({ businessId: BIZ, businessName: "Shop", completed: true, invitationStatus: "sent", after: life({ onboarding_status: "testing" }) }, life({ is_active: false, onboarding_status: "automation_setup" }))],
];

const FULL_EMAIL = /[A-Za-z0-9._%+-]{2,}@[A-Za-z0-9.-]+\.[a-z]{2,}/;   // a masked one reads "o…@domain"
const PHONE = /\d{7,}/;

Deno.test("every setup and lifecycle audit row has before and after values", () => {
  for (const [action, fields, result] of CASES) {
    const entry = AUDITED[action](fields, result);
    assert(entry.old_data && Object.keys(entry.old_data).length, `${action}: old_data`);
    assert(entry.new_data && Object.keys(entry.new_data).length, `${action}: new_data`);
  }
});

Deno.test("audit rows hold no full email or phone number (DB-13, PRV-2)", () => {
  for (const [action, fields, result] of CASES) {
    const text = JSON.stringify(AUDITED[action](fields, result));
    assertFalse(FULL_EMAIL.test(text), `${action}: ${text}`);
    assertFalse(PHONE.test(text.replace(/[0-9a-f]{8}-[0-9a-f-]{27}/g, "").replace(/\d{4}-\d{2}-\d{2}T[\d:.]+Z/g, "")), `${action}: ${text}`);
  }
  const business = AUDITED.setup_save_business({}, CASES[0][2]);
  assertEquals((business.new_data as Record<string, unknown>).contact_fields_changed, ["email", "phone"]);
  assertEquals(business.old_data, { name: "Old name", timezone: "America/New_York" });
});

Deno.test("before values never reach the browser: the response JSON leaves them out", () => {
  for (const [action, , result] of CASES) {
    const sent = JSON.parse(JSON.stringify(result));
    assertFalse("old@shop.example" in sent || JSON.stringify(sent).includes("old@"), action);
    assertFalse(JSON.stringify(sent).includes("Old name"), action);
  }
});

Deno.test("receptionist edits record which configuration calls got before and after (COM-04)", () => {
  const e = AUDITED.setup_save_receptionist(CASES[4][1], CASES[4][2]);
  assertEquals([(e.old_data as Record<string, unknown>).config_hash, (e.new_data as Record<string, unknown>).config_hash], ["a1", "b2"]);
});

Deno.test("a failed audit write raises an audit_write_failed alert and reports it", async () => {
  const calls: { name: string; args: Record<string, unknown> }[] = [];
  const admin = {
    from: () => ({ insert: () => Promise.resolve({ error: { message: "insert failed" } }) }),
    rpc: (name: string, args: Record<string, unknown>) => (calls.push({ name, args }), Promise.resolve({ data: "alert", error: null })),
  } as unknown as SupabaseClient;
  const ok = await writeAudit(admin, { userId: "admin-1", ip: null, userAgent: null }, { action: "business.suspended", business_id: BIZ, entity_type: "business" });
  assertFalse(ok);
  assertEquals(calls.length, 1);
  assertEquals([calls[0].name, calls[0].args.p_kind, calls[0].args.p_business_id, calls[0].args.p_severity], ["zella_platform_alert", "audit_write_failed", BIZ, "urgent"]);
  assert(AUDIT_WARNING.includes("could not be recorded"));
  const good = { from: () => ({ insert: () => Promise.resolve({ error: null }) }), rpc: () => { throw new Error("no alert expected"); } } as unknown as SupabaseClient;
  assert(await writeAudit(good, { userId: "admin-1", ip: null, userAgent: null }, { action: "business.suspended" }));
});
