// Pure parts of the voice-rules function (no network), shared with its tests.
// Request and reply shapes follow Vapi's server messages: a tool-calls request is answered with
// { results: [{ toolCallId, result | error }] }, one entry per tool call, each a single-line string, always HTTP 200.

export type Json = Record<string, unknown>;
export type ToolCall = { toolCallId: string; action: string | null; args: Json };
export type Plan =
  | { kind: "ignore"; reply: Json }
  | { kind: "tools"; providerCallId: string | null; calls: ToolCall[]; lookup: Json }
  | { kind: "transfer"; providerCallId: string | null; calledNumber: string | null; vapiNumberId: string | null; callerNumber: string | null }
  | { kind: "status"; record: Json };

const ACTIONS = ["rules", "message", "emergency", "transfer"];
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const PHONE = /^\+?[0-9() .-]{7,20}$/;
const obj = (v: unknown): Json => (v && typeof v === "object" && !Array.isArray(v) ? v as Json : {});
const MAX_CALLS = 10;

function callContext(m: Json) {
  const call = obj(m.call);
  const pn = Object.keys(obj(call.phoneNumber)).length ? obj(call.phoneNumber) : obj(m.phoneNumber);
  const cn = String(obj(call.customer).number || "");
  return {
    call,
    providerCallId: typeof call.id === "string" && call.id ? call.id.slice(0, 200) : null,
    calledNumber: typeof pn.number === "string" && PHONE.test(pn.number) ? pn.number : null,
    vapiNumberId: typeof call.phoneNumberId === "string" ? call.phoneNumberId.slice(0, 100) : typeof pn.id === "string" ? pn.id.slice(0, 100) : null,
    // the caller's own number comes from the phone network, never from what they say
    callerNumber: /^\+?[0-9]{7,15}$/.test(cn) ? cn : null,
  };
}

export function plan(body: unknown): Plan {
  const m = obj(obj(body).message);
  const ctx = callContext(m);

  if (m.type === "transfer-destination-request") {
    return { kind: "transfer", providerCallId: ctx.providerCallId, calledNumber: ctx.calledNumber, vapiNumberId: ctx.vapiNumberId, callerNumber: ctx.callerNumber };
  }

  if (m.type === "status-update") {
    const st = typeof m.status === "string" ? m.status : "";
    if (!ctx.providerCallId || !["ringing", "in-progress", "forwarding", "ended"].includes(st)) return { kind: "ignore", reply: {} };
    const t = typeof m.timestamp === "number" ? m.timestamp : Date.parse(String(m.timestamp || ""));
    const type = String(ctx.call.type || "");
    return { kind: "status", record: {
      p_provider_call_id: ctx.providerCallId, p_status: st, p_called_number: ctx.calledNumber, p_vapi_phone_number_id: ctx.vapiNumberId,
      p_from_number: ctx.callerNumber, p_direction: /inbound/i.test(type) ? "inbound" : /outbound/i.test(type) ? "outbound" : "other",
      p_event_at: Number.isNaN(t) ? null : new Date(t).toISOString(),
      p_ended_reason: typeof m.endedReason === "string" ? m.endedReason.slice(0, 80) : null,
    } };
  }

  const list = Array.isArray(m.toolCallList) ? m.toolCallList : Array.isArray(m.toolCalls) ? m.toolCalls : [];
  if (m.type !== "tool-calls" || !list.length) return { kind: "ignore", reply: { results: [] } };

  const nameOf = (t: Json) => String(t.name || obj(t.function).name || "");
  const calls: ToolCall[] = [];
  const seen = new Set<string>();
  for (const raw of (list as unknown[]).slice(0, MAX_CALLS)) {
    const tc = obj(raw);
    // a tool call without a usable id can't be answered; a repeated id in one request is answered once
    if (typeof tc.id !== "string" || !tc.id || tc.id.length > 200 || seen.has(tc.id)) continue;
    seen.add(tc.id);
    let args: unknown = tc.arguments !== undefined ? tc.arguments : obj(tc.function).arguments;
    if (typeof args === "string") { try { args = JSON.parse(args); } catch { args = {}; } }
    const a = obj(args);
    const action = typeof a.action === "string" ? a.action.trim().toLowerCase() : "rules";
    const clean: Json = {};
    for (const k of ["message", "name", "phone", "summary", "reason"]) {
      if (typeof a[k] === "string") clean[k] = (a[k] as string).replace(/\s+/g, " ").trim().slice(0, 1500);
    }
    if (ctx.callerNumber) { clean.caller_number = ctx.callerNumber; if (!clean.phone) clean.phone = ctx.callerNumber; }
    // only call_rules with a known action reaches the database; anything else gets its own error answer
    calls.push({ toolCallId: tc.id, action: nameOf(tc) === "call_rules" && ACTIONS.includes(action) ? action : null, args: clean });
  }
  if (!calls.length) return { kind: "ignore", reply: { results: [] } };

  const meta = obj(ctx.call.metadata);
  const vars = obj(obj(ctx.call.assistantOverrides).variableValues);
  const bid = [meta.business_id, vars.business_id].find((v) => typeof v === "string" && UUID.test(v)) as string | undefined;
  return { kind: "tools", providerCallId: ctx.providerCallId, calls,
    lookup: { p_called_number: ctx.calledNumber, p_vapi_phone_number_id: ctx.vapiNumberId, p_fallback: bid ?? null } };
}

export const FAILED = "This could not be done right now. Tell the caller the team will call them back. Do not promise anything else.";
export const UNSUPPORTED = "This tool is not available here. Offer to take a message instead.";
const line = (s: unknown, n: number) => String(s).replace(/[\r\n]+/g, " ").slice(0, n);

// The answer for one tool call. A caller the backend screened out gets the screening instruction (end politely, use no
// tools) in place of everything else. The transfer number is never given to the model: the system chooses it when Vapi
// sends transfer-destination-request.
export function toolResult(toolCallId: string, ok: boolean, b: Json | null): Json {
  if (!ok || !b || typeof b.say !== "string") return { toolCallId, error: FAILED };
  const caller = obj(b.caller);
  const scr = obj(caller.screening);
  const decision = typeof scr.decision === "string" ? scr.decision : null;
  let result: Json;
  if (b.status === "screened" || (decision && ["blocked", "restricted", "screened"].includes(decision) && typeof caller.say === "string")) {
    result = { status: "screened", instruction: line(b.status === "screened" ? b.say : caller.say, 600), can_transfer: false };
    if (Array.isArray(b.emergency_keywords)) result.emergency_words = b.emergency_keywords.slice(0, 20);   // emergencies are still allowed
  } else {
    result = { status: b.status, instruction: line(b.say + (typeof caller.say === "string" && caller.say ? " About this caller: " + caller.say : ""), 900) };
    if (typeof b.open === "boolean") result.open = b.open;
    if (typeof b.can_transfer === "boolean") result.can_transfer = b.can_transfer;
    if (b.status === "transfer") result.use_transfer_tool = true;
    if (Array.isArray(b.emergency_keywords)) result.emergency_words = b.emergency_keywords.slice(0, 20);
    if (decision === "flagged") result.caution = true;
  }
  return { toolCallId, result: JSON.stringify(result) };
}

export const unsupported = (toolCallId: string): Json => ({ toolCallId, error: UNSUPPORTED });

// Answer to Vapi's transfer-destination-request. Only a number the database authorised for this call's own business
// is returned; anything else is a refusal, so the assistant never says the transfer worked when it can't.
export function transferReply(ok: boolean, d: Json | null): Json {
  const r = obj(d);
  if (ok && r.ok === true && typeof r.number === "string" && /^\+[1-9][0-9]{7,14}$/.test(r.number)) {
    return { destination: { type: "number", number: r.number, message: line(typeof r.message === "string" ? r.message : "Please hold while I connect you.", 200) } };
  }
  return { error: line(typeof r.message === "string" ? r.message : "Transfer is not available right now.", 200) };
}

// Constant-time comparison for the shared secret.
export function sameSecret(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a), y = new TextEncoder().encode(b);
  let diff = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0 && x.length > 0;
}
