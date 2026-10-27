// Pure parts of the voice-rules function (no network), shared with its tests. Brain tool parsing and replies come from
// the shared vapi-brain-tools.js (the same code n8n Brain Tools runs).
// Request and reply shapes follow Vapi's ServerMessage schema (@vapi-ai/server-sdk 3.0.0): a tool-calls request is
// answered with { results: [{ name, toolCallId, result | error }] }, one entry per tool call, each a single-line string,
// always HTTP 200. Call events (status-update, end-of-call-report) are planned by the shared vapi-call-events.js.
import { planCallEvent } from "../_shared/vapi-call-events.js";
import { BRAIN_TOOLS, planBrainTool, toolArgs, toolCallList, toolName, vapiCallContext } from "../_shared/vapi-brain-tools.js";
export { brainInvalidReply, brainToolReply } from "../_shared/vapi-brain-tools.js";

export type Json = Record<string, unknown>;
// One tool call, as decided before any database work:
//   rules       call_rules with a known action  -> zella_ai_voice
//   brain       one of the 14 Receptionist Brain tools with valid arguments -> zella_ai_tool (the audited gateway)
//   invalid     a Brain tool with malformed arguments -> error answer, nothing done
//   unsupported anything else -> error answer, nothing done
export type ToolCall = {
  toolCallId: string; name: string; kind: "rules" | "brain" | "invalid" | "unsupported";
  action: string | null; args: Json; record?: Json; why?: string;
};
export type Plan =
  | { kind: "invalid" }
  | { kind: "ignore"; reply: Json }
  | { kind: "tools"; providerCallId: string | null; calls: ToolCall[]; lookup: Json }
  | { kind: "transfer"; providerCallId: string | null; calledNumber: string | null; vapiNumberId: string | null; callerNumber: string | null }
  | { kind: "status"; record: Json }
  | { kind: "report"; rpc: "zella_record_call_result" | "zella_record_inbound_call"; record: Json };

const ACTIONS = ["rules", "message", "emergency", "transfer"];
const obj = (v: unknown): Json => (v && typeof v === "object" && !Array.isArray(v) ? v as Json : {});

export function plan(body: unknown): Plan {
  // every Vapi server message is { message: { type, ... } }; anything else is refused before any database work
  const raw = obj(body).message;
  if (!raw || typeof raw !== "object" || Array.isArray(raw) || typeof (raw as Json).type !== "string") return { kind: "invalid" };
  const m = obj(raw);
  const ctx = vapiCallContext(m);

  if (m.type === "transfer-destination-request") {
    return { kind: "transfer", providerCallId: ctx.callId, calledNumber: ctx.calledNumber, vapiNumberId: ctx.vapiNumberId, callerNumber: ctx.callerNumber };
  }

  if (m.type === "status-update" || m.type === "end-of-call-report") {
    const ev = planCallEvent(m);
    if (ev.status) return { kind: "status", record: ev.status };
    if (ev.record) return { kind: "report", rpc: "zella_record_call_result", record: ev.record };
    if (ev.inbound) return { kind: "report", rpc: "zella_record_inbound_call", record: ev.inbound };
    return { kind: "ignore", reply: {} };
  }

  // a tool call without a usable id can't be answered; a repeated id in one request is answered once; at most 10
  const list = m.type === "tool-calls" ? toolCallList(m) : [];
  if (!list.length) return { kind: "ignore", reply: { results: [] } };

  const calls: ToolCall[] = list.map((tc) => {
    const name = toolName(tc);
    const id = tc.id as string;
    if (name === "call_rules") {
      const a = toolArgs(tc);
      const action = typeof a.action === "string" ? a.action.trim().toLowerCase() : "rules";
      const clean: Json = {};
      for (const k of ["message", "name", "phone", "summary", "reason"]) {
        if (typeof a[k] === "string") clean[k] = (a[k] as string).replace(/\s+/g, " ").trim().slice(0, 1500);
      }
      // the caller's own number comes from the phone network, never from what they say
      if (ctx.callerNumber) { clean.caller_number = ctx.callerNumber; if (!clean.phone) clean.phone = ctx.callerNumber; }
      return ACTIONS.includes(action) ? { toolCallId: id, name, kind: "rules", action, args: clean } : { toolCallId: id, name, kind: "unsupported", action: null, args: clean };
    }
    if (BRAIN_TOOLS.includes(name)) {
      const p = planBrainTool(tc, ctx);
      return p.invalid ? { toolCallId: id, name, kind: "invalid", action: null, args: {}, why: p.invalid }
        : { toolCallId: id, name, kind: "brain", action: null, args: {}, record: p.record };
    }
    return { toolCallId: id, name, kind: "unsupported", action: null, args: {} };
  });
  return { kind: "tools", providerCallId: ctx.callId, calls,
    lookup: { p_called_number: ctx.calledNumber, p_vapi_phone_number_id: ctx.vapiNumberId, p_fallback: ctx.fallbackBusinessId } };
}

export const FAILED = "This could not be done right now. Tell the caller the team will call them back. Do not promise anything else.";
export const UNSUPPORTED = "This tool is not available here. Offer to take a message instead.";
const line = (s: unknown, n: number) => String(s).replace(/[\r\n]+/g, " ").slice(0, n);

// The answer for one tool call. A caller the backend screened out gets the screening instruction (end politely, use no
// tools) in place of everything else. The transfer number is never given to the model: the system chooses it when Vapi
// sends transfer-destination-request.
export function toolResult(toolCallId: string, ok: boolean, b: Json | null, name = "call_rules"): Json {
  if (!ok || !b || typeof b.say !== "string") return { name, toolCallId, error: FAILED };
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
  return { name, toolCallId, result: JSON.stringify(result) };
}

export const unsupported = (toolCallId: string, name = ""): Json => ({ name, toolCallId, error: UNSUPPORTED });

// Answer to Vapi's transfer-destination-request. Only a number the database authorised for this call's own business
// is returned; anything else is a refusal, so the assistant never says the transfer worked when it can't.
export function transferReply(ok: boolean, d: Json | null): Json {
  const r = obj(d);
  if (ok && r.ok === true && typeof r.number === "string" && /^\+[1-9][0-9]{7,14}$/.test(r.number)) {
    return { destination: { type: "number", number: r.number, message: line(typeof r.message === "string" ? r.message : "Please hold while I connect you.", 200) } };
  }
  return { error: line(typeof r.message === "string" ? r.message : "Transfer is not available right now.", 200) };
}

// Headers handed to the database's signature check: only the ones it reads, lower-cased, short.
export const AUTH_HEADERS = ["x-signature", "x-timestamp", "authorization"];
export function authHeaders(h: Headers): Json {
  const out: Json = {};
  for (const k of AUTH_HEADERS) { const v = h.get(k); if (v !== null) out[k] = v.slice(0, 1000); }
  return out;
}

// What the caller of the endpoint is told when the check fails. Nothing more specific: a probe learns nothing.
export const AUTH_OK = "ok";
