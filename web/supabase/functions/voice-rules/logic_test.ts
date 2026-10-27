import { FAILED, plan, sameSecret, toolResult, transferReply, UNSUPPORTED, unsupported } from "./logic.ts";

function eq(a: unknown, b: unknown, m: string) { if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(m + ": " + JSON.stringify(a) + " !== " + JSON.stringify(b)); }
const BIZ = "3f1c2b4e-5a6d-4e7f-8a9b-0c1d2e3f4a5b";
const callObj = { id: "call-1", type: "inboundPhoneCall", customer: { number: "+15559990001" }, phoneNumber: { number: "+15550001111", id: "pn1" }, metadata: { business_id: BIZ } };
const toolMsg = (list: unknown[]) => ({ message: { type: "tool-calls", toolCallList: list, call: callObj } });
const rules = (id: string, args: unknown) => ({ id, name: "call_rules", arguments: args });
const parse = (r: Record<string, unknown>) => JSON.parse(r.result as string);

Deno.test("plans every tool call in one request, each with its own id", () => {
  const p = plan(toolMsg([rules("tc1", { action: "rules" }), rules("tc2", { action: "transfer", reason: "  wants   a person " }), rules("tc3", "{\"action\":\"message\",\"message\":\"hi\"}")]));
  if (p.kind !== "tools") throw new Error("not tools");
  eq(p.calls.map((c) => [c.toolCallId, c.action]), [["tc1", "rules"], ["tc2", "transfer"], ["tc3", "message"]], "ids and actions");
  eq(p.calls[1].args.reason, "wants a person", "args cleaned");
  eq(p.calls[0].args.caller_number, "+15559990001", "caller number from the network");
  eq(p.lookup, { p_called_number: "+15550001111", p_vapi_phone_number_id: "pn1", p_fallback: BIZ }, "lookup");
});
Deno.test("unknown tools and actions get their own error answer, not silence", () => {
  const p = plan(toolMsg([rules("tc1", { action: "rules" }), { id: "tc2", name: "delete_everything", arguments: {} }, rules("tc3", { action: "drop_table" })]));
  if (p.kind !== "tools") throw new Error("not tools");
  eq(p.calls.map((c) => c.action), ["rules", null, null], "only call_rules with a known action runs");
  eq(unsupported("tc2"), { toolCallId: "tc2", error: UNSUPPORTED }, "error entry");
});
Deno.test("tool calls without an id are skipped; repeated ids answered once; at most 10", () => {
  const many = Array.from({ length: 15 }, (_, i) => rules("t" + i, { action: "rules" }));
  const p = plan(toolMsg([{ name: "call_rules", arguments: {} }, rules("dup", {}), rules("dup", {}), ...many]));
  if (p.kind !== "tools") throw new Error("not tools");
  eq(p.calls[0].toolCallId, "dup", "no-id skipped"); eq(p.calls.filter((c) => c.toolCallId === "dup").length, 1, "dup once");
  eq(p.calls.length <= 10, true, "capped");
});
Deno.test("non-tool messages are not sent to the database", () => {
  eq(plan({ message: { type: "speech-update" } }).kind, "ignore", "other");
  eq(plan({}).kind, "ignore", "empty");
  eq(plan(toolMsg([])).kind, "ignore", "no calls");
});
Deno.test("a screened caller gets the screening instruction, and no transfer", () => {
  const r = parse(toolResult("tc1", true, { ok: true, status: "open", say: "Acme is open now.", can_transfer: true, emergency_keywords: ["bleeding"],
    caller: { say: "Spam protection: this caller is not accepted. End the call.", screening: { decision: "blocked", level: "high" } } }));
  eq(r.status, "screened", "status"); eq(r.can_transfer, false, "no transfer"); eq(r.emergency_words, ["bleeding"], "emergencies still recognised");
  eq(parse(toolResult("tc1", true, { ok: false, status: "screened", say: "Do not transfer." })).status, "screened", "database refusal passed on");
});
Deno.test("a transfer result tells the model to use the transfer tool and never contains the number", () => {
  const r = toolResult("tc1", true, { ok: true, status: "transfer", transfer_number: "+15550109999", say: "Connect them." });
  eq(parse(r).use_transfer_tool, true, "flag"); eq(String(r.result).includes("5550109999"), false, "number not exposed");
});
Deno.test("a normal caller gets the rules plus the caller note; a flagged caller gets a caution", () => {
  eq(parse(toolResult("tc1", true, { status: "open", say: "Open.", caller: { say: "New caller." } })).instruction, "Open. About this caller: New caller.", "note");
  eq(parse(toolResult("tc1", true, { status: "open", say: "Open.", caller: { say: "x", screening: { decision: "flagged" } } })).caution, true, "caution");
});
Deno.test("failures use Vapi's error field with a safe instruction; text is single-line", () => {
  eq(toolResult("tc1", false, null), { toolCallId: "tc1", error: FAILED }, "failed");
  eq(String(toolResult("tc1", true, { status: "open", say: "a\nb" }).result).includes("\\n"), false, "no line breaks");
});
Deno.test("transfer-destination-request: authorised number only, refusal otherwise", () => {
  const p = plan({ message: { type: "transfer-destination-request", call: callObj } });
  if (p.kind !== "transfer") throw new Error("not transfer");
  eq([p.providerCallId, p.calledNumber, p.vapiNumberId, p.callerNumber], ["call-1", "+15550001111", "pn1", "+15559990001"], "context");
  eq(transferReply(true, { ok: true, number: "+15550101111", message: "Please hold." }), { destination: { type: "number", number: "+15550101111", message: "Please hold." } }, "ok");
  eq("error" in transferReply(true, { ok: false, message: "Can't connect." }), true, "refused");
  eq("error" in transferReply(true, { ok: true, number: "555-0101" }), true, "non-E.164 never used");
  eq("error" in transferReply(false, null), true, "database down: refused");
});
Deno.test("status-update becomes one status record; unknown statuses ignored", () => {
  const p = plan({ message: { type: "status-update", status: "in-progress", timestamp: 1793102400000, call: callObj } });
  if (p.kind !== "status") throw new Error("not status");
  eq(p.record.p_status, "in-progress", "status"); eq(p.record.p_direction, "inbound", "direction"); eq(p.record.p_event_at, new Date(1793102400000).toISOString(), "time");
  eq(plan({ message: { type: "status-update", status: "queued", call: callObj } }).kind, "ignore", "queued ignored");
  eq(plan({ message: { type: "status-update", status: "ended" } }).kind, "ignore", "no call id");
});
Deno.test("secret comparison", () => {
  eq(sameSecret("abc", "abc"), true, "same"); eq(sameSecret("abc", "abd"), false, "diff"); eq(sameSecret("", ""), false, "empty never matches"); eq(sameSecret("abc", "abcd"), false, "length");
});
