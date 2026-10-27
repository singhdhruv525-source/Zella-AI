// Zella: the Vapi server endpoint (assistant server URL and every tool's server URL). Answers, without n8n:
//   tool-calls                         every tool call in the request, each under its own toolCallId:
//                                        call_rules -> zella_ai_voice; the 14 Receptionist Brain tools -> zella_ai_tool
//   transfer-destination-request       the number this call's own business authorised, or a refusal (zella_transfer_destination)
//   status-update                      the call's status, once and in order (zella_record_call_status)
//   end-of-call-report                 the call's record (zella_record_inbound_call / zella_record_call_result)
// Everything else is acknowledged and ignored. n8n Brain Tools runs the same parsing code and stays as the rollback path;
// both go through zella_ai_tool with the same idempotency key, so a tool call delivered to both runs once.
//
// Authentication: Vapi's HMAC credential (or Bearer). The database checks the exact request bytes, the signature, the
// timestamp (5 minutes) and that the request was not seen before (zella_vapi_authenticate); the secret lives only in
// Vault. Nothing is read from or written to the database for a request that fails the check.
// Public function (deploy with --no-verify-jwt: Vapi has no Supabase sign-in); the check above is the gate.
// Timing: Vapi waits up to the server timeout (20 s by default). Every database call here gives up after RPC_MS and the
// whole request after BUDGET_MS, answering with a safe failure (assistant takes no action; transfer refused).

import { createClient } from "@supabase/supabase-js";
import { AUTH_OK, authHeaders, brainInvalidReply, brainToolReply, plan, type ToolCall, toolResult, transferReply, unsupported } from "./logic.ts";

const json = (data: unknown, status = 200) => Response.json(data, { status });
const MAX_BODY = 256 * 1024;
const RPC_MS = Number(Deno.env.get("ZELLA_VOICE_RPC_MS") ?? 4000);
const BUDGET_MS = Number(Deno.env.get("ZELLA_VOICE_BUDGET_MS") ?? 12000);
// deno-lint-ignore no-explicit-any
type Db = any;
type RpcOut = { data: unknown; error: { code?: string; message?: string } | null };

// one database call with a time limit; a timeout or network failure is an error, never an answer
async function call(db: Db, fn: string, args: Record<string, unknown>, ms = RPC_MS): Promise<RpcOut> {
  try {
    const r = await db.rpc(fn, args).abortSignal(AbortSignal.timeout(Math.max(1, ms)));
    if (r.error) console.error(fn + " failed", r.error.code ?? "", (r.error.message ?? "").slice(0, 120));
    return { data: r.data, error: r.error };
  } catch (e) {
    console.error(fn + " failed", String(e).slice(0, 120));
    return { data: null, error: { message: "unreachable" } };
  }
}

// Timings for each request (milliseconds), in the Server-Timing header and one log line. No caller data is logged.
type Timing = Record<string, number>;
const respond = (data: unknown, status: number, t: Timing, started: number, kind: string) => {
  t.total = Date.now() - started;
  console.log(JSON.stringify({ voice: kind, status, ...t }));
  const r = Response.json(data, { status });
  r.headers.set("server-timing", Object.entries(t).map(([k, v]) => `${k};dur=${v}`).join(", "));
  return r;
};
const timed = async <T>(t: Timing, key: string, f: () => Promise<T>): Promise<T> => {
  const s0 = Date.now();
  try { return await f(); } finally { t[key] = (t[key] ?? 0) + Date.now() - s0; }
};

Deno.serve(async (req: Request) => {
  const started = Date.now();
  const t: Timing = {};
  const left = () => Math.min(RPC_MS, BUDGET_MS - (Date.now() - started));
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("ZELLA_SERVER_SECRET_KEY");
  if (!url || !key) {
    console.error("voice-rules configuration is missing");
    return json({ error: "Not configured" }, 500);
  }
  if (Number(req.headers.get("content-length") ?? 0) > MAX_BODY) return json({ error: "Too large" }, 413);
  // the exact bytes are needed for the signature, so the body is read as text first
  let raw: string;
  try { raw = await req.text(); } catch { return json({ error: "Bad request" }, 400); }
  if (new TextEncoder().encode(raw).length > MAX_BODY) return json({ error: "Too large" }, 413);

  const db = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
  const auth = await timed(t, "auth", () => call(db, "zella_vapi_authenticate", { p_raw: raw, p_headers: authHeaders(req.headers) }));
  if (auth.error) return respond({ error: "Unavailable" }, 503, t, started, "auth_unavailable");   // can't check: refuse, never guess
  if (auth.data !== AUTH_OK) return respond({ error: "Unauthorized" }, 401, t, started, "refused_" + String(auth.data).slice(0, 20));

  let body: unknown;
  try { body = JSON.parse(raw); } catch { return respond({ error: "Bad request" }, 400, t, started, "bad_json"); }
  const p = plan(body);
  if (p.kind === "invalid") return respond({ error: "Bad request" }, 400, t, started, "bad_message");
  if (p.kind === "ignore") return respond(p.reply, 200, t, started, "ignored");

  if (p.kind === "status" || p.kind === "report") {
    // Vapi does not use the answer; a failure is logged and the call is picked up by reconciliation later
    await timed(t, "db", () => call(db, p.kind === "status" ? "zella_record_call_status" : p.rpc, p.record, left()));
    return respond({}, 200, t, started, p.kind);
  }

  if (p.kind === "transfer") {
    const r = await timed(t, "db", () => call(db, "zella_transfer_destination", {
      p_provider_call_id: p.providerCallId, p_called_number: p.calledNumber, p_vapi_phone_number_id: p.vapiNumberId, p_from_number: p.callerNumber,
    }, left()));
    return respond(transferReply(!r.error, r.data as Record<string, unknown>), 200, t, started, "transfer");
  }

  // Tool calls: one answer per tool call id, in the same order; one failure never loses the others. The business is
  // looked up once (a registered number always wins over call settings; with no business the database refuses to act).
  // The tool calls of one turn are independent, so they run at the same time; the database serialises anything that
  // must not overlap (booking locks, in-flight idempotency).
  // After the signature check, the business lookup and each tool call's rate-limit check run together (both read-only
  // or counters), then the tool calls run together. Nothing runs before the signature check.
  const dbCalls = p.calls.filter((c) => c.kind === "rules" || c.kind === "brain");
  let businessId: string | null = null;
  let lookupFailed = false;
  const limited = new Set<ToolCall>();
  if (dbCalls.length) {
    await timed(t, "lookup", () => Promise.all([
      call(db, "zella_business_for_number", p.lookup, left()).then((found) => {
        lookupFailed = !!found.error;
        businessId = typeof found.data === "string" ? found.data : null;
      }),
      // a runaway assistant can't hammer the database: 30 tool calls a minute per call (a counter problem never blocks)
      ...(p.providerCallId ? dbCalls.map((c) => call(db, "zella_rate_limit", { p_key: "voice:" + p.providerCallId, p_max: 30, p_window_seconds: 60 }, left())
        .then((rl) => { if (!rl.error && rl.data === false) limited.add(c); })) : []),
    ]));
  }
  const fail = (c: ToolCall) => c.kind === "brain" ? brainToolReply(c.name, c.toolCallId, false, null) : toolResult(c.toolCallId, false, null, c.name);
  const runOne = async (c: ToolCall): Promise<Record<string, unknown>> => {
    if (c.kind === "unsupported") return unsupported(c.toolCallId, c.name);
    if (c.kind === "invalid") return brainInvalidReply(c.name, c.toolCallId, c.why ?? "bad arguments");
    if (lookupFailed || limited.has(c) || left() < 200) return fail(c);   // dependency down, over the limit or out of time
    if (c.kind === "rules") {
      const r = await call(db, "zella_ai_voice", { p_provider_call_id: p.providerCallId, p_business_id: businessId, p_action: c.action, p_args: c.args }, left());
      return toolResult(c.toolCallId, !r.error, r.data as Record<string, unknown>, c.name);
    }
    const r = await call(db, "zella_ai_tool", { ...c.record, p_business_id: businessId }, left());
    return brainToolReply(c.name, c.toolCallId, !r.error, r.data);
  };
  const results = await timed(t, "tools", () => Promise.all(p.calls.map(runOne)));
  t.calls = p.calls.length;
  t.failed = results.filter((r) => "error" in r).length;
  return respond({ results }, 200, t, started, "tools");
});
