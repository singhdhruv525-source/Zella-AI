// deno test --no-lock web/supabase/functions/_shared/billingEmails_test.ts   (no network: the database is stubbed)
import { assert, assertEquals } from "jsr:@std/assert@1";
import { queueBillingEmails } from "./billingEmails.ts";

function stub(intents: unknown[]) {
  const calls: { fn: string; args: Record<string, unknown> }[] = [];
  const rpc = (fn: string, args: Record<string, unknown>) => {
    calls.push({ fn, args });
    if (fn === "zella_billing_email_claim") return Promise.resolve(intents);
    return Promise.resolve("ok");
  };
  return { rpc, calls };
}
const owner = { user_id: "u1", email: "owner@example.test", owner: "Jordan" };

Deno.test("a notice with every fact is rendered once per owner into the platform outbox, keyed on the business object", async () => {
  const s = stub([{ id: "i1", business_id: "b1", code: "D5", dedupe_key: "email:D5:sub1:20261116", data: { appUrl: "https://app.example.test", fallbackPhone: "+15550100000", business: "Glow" }, recipients: [owner, { ...owner, user_id: "u2", email: "two@example.test" }] }]);
  assertEquals(await queueBillingEmails(s.rpc), { queued: 1 });
  const q = s.calls.filter((c) => c.fn === "zella_queue_platform_email");
  assertEquals(q.map((c) => c.args.p_dedupe_key), ["email:D5:sub1:20261116:u1", "email:D5:sub1:20261116:u2"]);
  assert(String(q[0].args.p_subject).includes("paused"));
  assertEquals(q[0].args.p_mandatory, true);
  assertEquals(s.calls.at(-1)!.args, { p_id: "i1", p_status: "queued", p_error: null });
});

Deno.test("a missing fact holds the email instead of inventing a value; no owner holds it too", async () => {
  const s = stub([
    { id: "i2", business_id: "b1", code: "C3", dedupe_key: "email:C3:in1:1", data: { appUrl: "https://app.example.test", invoice: "ZV-1", total: "$299.00", date: "16 Nov 2026" }, recipients: [owner] },
    { id: "i3", business_id: "b1", code: "D5", dedupe_key: "email:D5:s:1", data: { fallbackPhone: "+1555" }, recipients: [] },
  ]);
  assertEquals(await queueBillingEmails(s.rpc), { held: 2 });
  assertEquals(s.calls.filter((c) => c.fn === "zella_queue_platform_email").length, 0);
  const done = s.calls.filter((c) => c.fn === "zella_billing_email_done").map((c) => [c.args.p_status, c.args.p_error]);
  assertEquals(done, [["held", "MISSING_FIELD:C3:card"], ["held", "NO_RECIPIENT"]]);
});
