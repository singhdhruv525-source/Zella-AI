import { plan, reply, sameSecret, FAILED } from "./logic.ts";

function eq(a: unknown, b: unknown, m: string) { if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(m + ": " + JSON.stringify(a) + " !== " + JSON.stringify(b)); }
const BIZ = "3f1c2b4e-5a6d-4e7f-8a9b-0c1d2e3f4a5b";
const body = (args: unknown, extra = {}) => ({ message: { type: "tool-calls", toolCallList: [{ id: "tc1", name: "call_rules", arguments: args }],
  call: { id: "call-1", customer: { number: "+15559990001" }, phoneNumber: { number: "+15550001111", id: "pn1" }, metadata: { business_id: BIZ }, ...extra } } });
const parse = (r: Record<string, unknown>) => JSON.parse(((r.results as Record<string, unknown>[])[0]).result as string);

Deno.test("plans a call_rules tool call with caller number from the network", () => {
  const p = plan(body({ action: "transfer", reason: "  wants   a person ", caller_number: "+19999999999" }));
  if (p.kind !== "tool") throw new Error("not a tool");
  eq(p.action, "transfer", "action"); eq(p.args.reason, "wants a person", "clean"); eq(p.args.caller_number, "+15559990001", "caller from network, not args");
  eq(p.lookup, { p_called_number: "+15550001111", p_vapi_phone_number_id: "pn1", p_fallback: BIZ }, "lookup");
});
Deno.test("other messages and unknown actions are not sent to the database", () => {
  eq(plan({ message: { type: "status-update" } }).kind, "ignore", "status update");
  eq(plan({}).kind, "ignore", "empty");
  const p = plan(body({ action: "delete_everything" }));
  eq(p.kind, "ignore", "unknown action");
});
Deno.test("a screened caller gets the screening instruction, no transfer", () => {
  const r = parse(reply("tc1", true, { ok: true, status: "open", say: "Acme is open now.", can_transfer: true, emergency_keywords: ["bleeding"],
    caller: { say: "Spam protection: this caller is not accepted. End the call.", screening: { decision: "blocked", level: "high" } } }));
  eq(r.status, "screened", "status"); eq(r.instruction, "Spam protection: this caller is not accepted. End the call.", "instruction");
  eq(r.can_transfer, false, "no transfer"); eq(r.emergency_words, ["bleeding"], "emergencies still recognised"); eq(r.transfer_number, undefined, "no number");
});
Deno.test("the database refusing an action for a screened caller is passed on", () => {
  const r = parse(reply("tc1", true, { ok: false, status: "screened", say: "Spam protection: do not transfer." }));
  eq(r.status, "screened", "status"); eq(r.instruction, "Spam protection: do not transfer.", "say");
});
Deno.test("a normal caller gets the rules plus the caller note (this was dropped before)", () => {
  const r = parse(reply("tc1", true, { ok: true, status: "open", say: "Acme is open now.", open: true, can_transfer: true, caller: { say: "New caller. Ask for their name." } }));
  eq(r.instruction, "Acme is open now. About this caller: New caller. Ask for their name.", "instruction"); eq(r.can_transfer, true, "transfer");
});
Deno.test("a flagged caller is helped normally with a caution flag", () => {
  const r = parse(reply("tc1", true, { ok: true, status: "open", say: "Open.", caller: { say: "Flagged as possible spam.", screening: { decision: "flagged" } } }));
  eq(r.status, "open", "status"); eq(r.caution, true, "caution");
});
Deno.test("database failure: safe instruction, no details", () => {
  eq(parse(reply("tc1", false, null)), { status: "error", instruction: FAILED }, "failed");
});
Deno.test("secret comparison", () => {
  eq(sameSecret("abc", "abc"), true, "same"); eq(sameSecret("abc", "abd"), false, "diff"); eq(sameSecret("", ""), false, "empty never matches"); eq(sameSecret("abc", "abcd"), false, "length");
});
