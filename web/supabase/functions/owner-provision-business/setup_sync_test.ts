// deno test --no-lock web/supabase/functions/owner-provision-business/setup_sync_test.ts   (no network)
import { assertEquals } from "jsr:@std/assert@1";
import { fallbackPatch, sameLine, toE164, transferPatch } from "./setup_sync.ts";

const base = { transferType: "owner", transferPhone: null, integrationsNumber: null, ownerPhone: null, currentNumber: null, currentSource: null };

Deno.test("transfer number: receptionist phone, then integrations number, then the owner's phone (owner only)", () => {
  assertEquals(transferPatch({ ...base, transferPhone: "+15550001", integrationsNumber: "+15550002", ownerPhone: "+15550003" })?.transfer_number, "+15550001");
  assertEquals(transferPatch({ ...base, integrationsNumber: "+15550002", ownerPhone: "+15550003" })?.transfer_number, "+15550002");
  assertEquals(transferPatch({ ...base, ownerPhone: "+15550003" })?.transfer_number, "+15550003");
  assertEquals(transferPatch({ ...base, transferType: "manager", ownerPhone: "+15550003" }), null);   // not the owner: no guess
});

Deno.test("a number set in admin call routing is never replaced; setup's own number follows setup", () => {
  assertEquals(transferPatch({ ...base, ownerPhone: "+15550003", currentNumber: "+15559999", currentSource: null }), null);
  assertEquals(transferPatch({ ...base, ownerPhone: "+15550003", currentNumber: "+15550001", currentSource: "setup" })?.transfer_number, "+15550003");
  assertEquals(transferPatch({ ...base, ownerPhone: "+15550003", currentNumber: "+15550003", currentSource: "setup" }), null);   // unchanged
  // setup's number removed: cleared (only when setup wrote it)
  assertEquals(transferPatch({ ...base, currentNumber: "+15550001", currentSource: "setup" })?.transfer_number, null);
});

Deno.test("fallback number: E.164 from what people type; never replaces an admin's number", () => {
  assertEquals(toE164("(555) 210-3000"), "+15552103000");
  assertEquals(toE164("1 555 210 3000"), "+15552103000");
  assertEquals(toE164("+44 20 7946 0000"), "+442079460000");
  assertEquals(toE164("+0123456789"), null);
  assertEquals(toE164("0123456789"), null);
  assertEquals(toE164(""), null);
  const fb = (setupNumber: string, currentNumber: string | null, currentFromSetup: string | null) => fallbackPatch({ setupNumber, currentNumber, currentFromSetup });
  assertEquals(fb("(555) 210-3000", null, null), { fallback_number: "+15552103000", fallback_number_source: "setup", fallback_number_from_setup: "+15552103000" });
  // an admin's number (never written by setup) stays
  assertEquals(fb("(555) 210-3000", "+15559990000", null), null);
  // setup wrote it, then an admin changed it: stays, even though an old marker may still say "setup"
  assertEquals(fb("(555) 210-3000", "+15559990000", "+15551110000"), null);
  // still exactly what setup wrote: setup may update it
  assertEquals(fb("(555) 210-3000", "+15551110000", "+15551110000")?.fallback_number, "+15552103000");
  assertEquals(fb("(555) 210-3000", "+15552103000", "+15552103000"), null);
  assertEquals(fb("bad", null, null), null);
  assertEquals(sameLine("(555) 210-3000", "+15552103000"), true);
  assertEquals(sameLine("(555) 210-3000", "+15552103001"), false);
  assertEquals(sameLine("", ""), false);
});
