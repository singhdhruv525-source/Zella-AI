// Zella Voice: business-export, the whole business export worker (logic.ts). Server only: it answers only a request
// that carries the server key, which only the timed job has; that job is created off and is the owner's switch.
// verify_jwt is off (config.toml): the server key is not a JWT.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { runExport } from "./logic.ts";

const json = (body: unknown, status: number) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
const TIMEOUT_MS = 20_000;

export async function handle(req: Request): Promise<Response> {
  if (req.method !== "POST") return json({ ok: false, error: "method_not_allowed" }, 405);
  const base = Deno.env.get("SUPABASE_URL"), server = Deno.env.get("ZELLA_SERVER_SECRET_KEY");
  if (!base || !server) return json({ ok: false, error: "try_again" }, 503);
  if (req.headers.get("authorization") !== `Bearer ${server}`) return json({ ok: false, error: "server_only" }, 403);
  const headers = { apikey: server, Authorization: `Bearer ${server}` };
  const enc = (p: string) => p.split("/").map(encodeURIComponent).join("/");
  try {
    const result = await runExport({
      async rpc(fn, args) {
        const r = await fetch(`${base}/rest/v1/rpc/${fn}`, { method: "POST", headers: { ...headers, "Content-Type": "application/json" }, body: JSON.stringify(args), signal: AbortSignal.timeout(TIMEOUT_MS) });
        const text = await r.text();
        if (!r.ok) return { data: null, error: { message: text.slice(0, 300) } };
        return { data: text ? JSON.parse(text) : null, error: null };
      },
      async upload(path, body, contentType) {
        const r = await fetch(`${base}/storage/v1/object/business-exports/${enc(path)}`, { method: "POST", headers: { ...headers, "Content-Type": contentType, "x-upsert": "true" }, body: body as BodyInit, signal: AbortSignal.timeout(TIMEOUT_MS) });
        await r.body?.cancel();
        return r.ok;
      },
      async download(bucket, path) {
        const r = await fetch(`${base}/storage/v1/object/${bucket}/${enc(path)}`, { headers, signal: AbortSignal.timeout(TIMEOUT_MS) });
        if (!r.ok) { await r.body?.cancel(); return null; }
        return { body: new Uint8Array(await r.arrayBuffer()), type: r.headers.get("content-type") ?? "application/octet-stream" };
      },
    });
    return json({ ok: true, ...result }, 200);
  } catch {
    return json({ ok: false, error: "try_again" }, 503);
  }
}

if (import.meta.main) Deno.serve(handle);
