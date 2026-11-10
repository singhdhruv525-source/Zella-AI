// deno test --no-lock web/supabase/functions/owner-provision-business/setup_sync_test.ts   (no network)
import { assertEquals } from "jsr:@std/assert@1";
import { transferPatch } from "./setup_sync.ts";

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
