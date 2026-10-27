// Pure parts of the voice-rules function (no network), shared with its tests.
// Same request and reply shapes as the n8n "Zella - Voice Rules" workflow (n8n/src/voice-tool-plan.js and
// voice-tool-reply.js), so Vapi's call_rules tool only needs a new URL.

export type Json = Record<string, unknown>;
export type Plan =
  | { kind: "ignore"; reply: Json }
  | { kind: "tool"; toolCallId: string; providerCallId: string | null; action: string; args: Json; lookup: Json; fallbackBusiness: string | null };

const ACTIONS = ["rules", "message", "emergency", "transfer"];
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const obj = (v: unknown): Json => (v && typeof v === "object" && !Array.isArray(v) ? v as Json : {});

export function plan(body: unknown): Plan {
  const m = obj(obj(body).message);
  const list = Array.isArray(m.toolCallList) ? m.toolCallList : Array.isArray(m.toolCalls) ? m.toolCalls : [];
  const nameOf = (t: Json) => String(t.name || obj(t.function).name || "");
  const tc = (list as Json[]).find((t) => t && typeof t.id === "string" && nameOf(obj(t)) === "call_rules");
  if (m.type !== "tool-calls" || !tc) return { kind: "ignore", reply: { results: [] } };

  let args: unknown = tc.arguments !== undefined ? tc.arguments : obj(tc.function).arguments;
  if (typeof args === "string") { try { args = JSON.parse(args); } catch { args = {}; } }
  const a = obj(args);
  const action = typeof a.action === "string" ? a.action.trim().toLowerCase() : "rules";
  if (!ACTIONS.includes(action)) {
    return { kind: "ignore", reply: { results: [{ toolCallId: tc.id, result: JSON.stringify({ status: "error", instruction: "Use action rules, message, emergency or transfer." }) }] } };
  }
  // Only known fields go on; the caller's words are data, never instructions.
  const clean: Json = {};
  for (const k of ["message", "name", "phone", "summary", "reason"]) {
    if (typeof a[k] === "string") clean[k] = (a[k] as string).replace(/\s+/g, " ").trim().slice(0, 1500);
  }
  const call = obj(m.call);
  const meta = obj(call.metadata);
  const vars = obj(obj(call.assistantOverrides).variableValues);
  const bid = [meta.business_id, vars.business_id].find((v) => typeof v === "string" && UUID.test(v)) as string | undefined;
  const pn = Object.keys(obj(call.phoneNumber)).length ? obj(call.phoneNumber) : obj(m.phoneNumber);
  const calledNumber = typeof pn.number === "string" && /^\+?[0-9() .-]{7,20}$/.test(pn.number) ? pn.number : null;
  const vapiNumberId = typeof call.phoneNumberId === "string" ? call.phoneNumberId.slice(0, 100) : typeof pn.id === "string" ? pn.id.slice(0, 100) : null;
  // The caller's own number comes from the phone network, never from what they say.
  const cn = String(obj(call.customer).number || "");
  if (/^\+?[0-9]{7,15}$/.test(cn)) { clean.caller_number = cn; if (!clean.phone) clean.phone = cn; }
  return {
    kind: "tool", toolCallId: tc.id as string, providerCallId: typeof call.id === "string" ? call.id.slice(0, 200) : null, action, args: clean,
    lookup: { p_called_number: calledNumber, p_vapi_phone_number_id: vapiNumberId, p_fallback: bid ?? null }, fallbackBusiness: bid ?? null,
  };
}

export const FAILED = "This could not be done right now. Tell the caller the team will call them back. Do not promise anything else.";

// The answer Vapi reads back to the assistant. A caller the backend screened out gets the screening instruction
// (end politely, use no tools) in place of everything else; other callers get the caller note added.
export function reply(toolCallId: string, ok: boolean, b: Json | null): Json {
  let result: Json;
  if (ok && b && typeof b.say === "string") {
    const caller = obj(b.caller);
    const scr = obj(caller.screening);
    const decision = typeof scr.decision === "string" ? scr.decision : null;
    if (b.status === "screened" || (decision && ["blocked", "restricted", "screened"].includes(decision) && typeof caller.say === "string")) {
      result = { status: "screened", instruction: b.status === "screened" ? b.say : caller.say, can_transfer: false };
      if (Array.isArray(b.emergency_keywords)) result.emergency_words = b.emergency_keywords.slice(0, 20);   // emergencies are still allowed
    } else {
      result = { status: b.status, instruction: b.say + (typeof caller.say === "string" && caller.say ? " About this caller: " + caller.say : "") };
      if (typeof b.open === "boolean") result.open = b.open;
      if (typeof b.can_transfer === "boolean") result.can_transfer = b.can_transfer;
      if (b.status === "transfer" && typeof b.transfer_number === "string" && /^\+?[0-9]{7,15}$/.test(b.transfer_number)) result.transfer_number = b.transfer_number;
      if (Array.isArray(b.emergency_keywords)) result.emergency_words = b.emergency_keywords.slice(0, 20);
      if (decision === "flagged") result.caution = true;
    }
  } else {
    result = { status: "error", instruction: FAILED };
  }
  return { results: [{ toolCallId, result: JSON.stringify(result) }] };
}

// Constant-time comparison for the shared secret.
export function sameSecret(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a), y = new TextEncoder().encode(b);
  let diff = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0 && x.length > 0;
}
