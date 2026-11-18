// Zella Voice - provider-deletions: deletes calls at Vapi (recording, transcript and the call) that the database queued
// (sql/zella_privacy_retention.sql: retention after 90 days, a customer's erasure, an account deletion).
//   POST {}   the server key only. Claims due rows (zella_provider_deletions_claim, which hands out nothing while the
//             platform setting vapi_deletion_live is off), sends DELETE https://api.vapi.ai/call/<id> for each, and
//             records the result (done; not_found when Vapi no longer has it; failed is retried later, alerted after 10).
// Needs VAPI_API_KEY to send anything; without it every claimed row is recorded as failed ("not configured") and
// retried. Off until the owner turns vapi_deletion_live on (a live provider change). verify_jwt is off: the server key
// is not a JWT; it is compared here.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

type Row = { id: string; provider: string; kind: string; external_id: string };
export type Deps = {
  rpc: (fn: string, args: Record<string, unknown>) => Promise<{ ok: boolean; data: unknown }>;
  vapiDelete: (callId: string) => Promise<number>;   // HTTP status
};
function same(a: string, b: string) { if (a.length !== b.length) return false; let d = 0; for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i); return d === 0; }
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { "Content-Type": "application/json" } });

export async function runOnce(deps: Deps, hasKey: boolean) {
  const claimed = await deps.rpc("zella_provider_deletions_claim", { p_limit: 20 });
  if (!claimed.ok || !Array.isArray(claimed.data)) return { error: "claim_failed" };
  const out = { done: 0, not_found: 0, failed: 0 };
  for (const r of claimed.data as Row[]) {
    let outcome: "done" | "not_found" | "failed" = "failed", error: string | null = null;
    if (r.provider !== "vapi" || r.kind !== "call" || !/^[A-Za-z0-9_-]{1,200}$/.test(r.external_id)) error = "unsupported";
    else if (!hasKey) error = "not configured";
    else {
      try {
        const status = await deps.vapiDelete(r.external_id);
        if (status >= 200 && status < 300) outcome = "done";
        else if (status === 404) outcome = "not_found";
        else error = `vapi ${status}`;
      } catch (e) { error = e instanceof Error ? e.name : "network"; }
    }
    await deps.rpc("zella_provider_deletion_result", { p_id: r.id, p_outcome: outcome, p_error: error });
    out[outcome]++;
  }
  return out;
}

export async function handle(req: Request, deps?: Deps): Promise<Response> {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  const base = Deno.env.get("SUPABASE_URL") ?? "", server = Deno.env.get("ZELLA_SERVER_SECRET_KEY") ?? "", vapiKey = Deno.env.get("VAPI_API_KEY") ?? "";
  if (!base || server.length < 20) return json({ error: "not_configured" }, 503);
  if (!same(req.headers.get("authorization") ?? "", `Bearer ${server}`)) return json({ error: "server_only" }, 401);
  const d: Deps = deps ?? {
    rpc: async (fn, args) => {
      const r = await fetch(`${base}/rest/v1/rpc/${fn}`, { method: "POST", headers: { "Content-Type": "application/json", apikey: server, Authorization: `Bearer ${server}` },
        body: JSON.stringify(args), signal: AbortSignal.timeout(10_000) }).catch(() => null);
      return { ok: !!r?.ok, data: r?.ok ? await r.json().catch(() => null) : null };
    },
    vapiDelete: async (id) => (await fetch(`https://api.vapi.ai/call/${encodeURIComponent(id)}`, { method: "DELETE", headers: { Authorization: `Bearer ${vapiKey}` }, signal: AbortSignal.timeout(10_000) })).status,
  };
  return json(await runOnce(d, vapiKey.length > 0));
}

if (import.meta.main) Deno.serve((req) => handle(req));
