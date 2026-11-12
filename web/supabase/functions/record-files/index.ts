// Zella Voice - files on records. Two jobs (sql/zella_record_files.sql):
//   check    after an upload, as the uploader: confirms it arrived (their sign-in, so their permissions apply), reads the
//            stored bytes with the server key, checks what the file really is (inspect.ts), and records the verdict.
//            A refused file is rejected and its stored copy deleted.
//   cleanup  server only (the server key, run on a schedule once approved): deletes stored copies of removed, rejected
//            and abandoned files and objects with no file record.
// verify_jwt is off (config.toml): the server key is not a JWT. "check" is verified by the database with the member's own
// sign-in; "cleanup" compares the server key.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { inspect, sha256 } from "./inspect.ts";

const json = (body: unknown, status: number) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info", "Access-Control-Allow-Methods": "POST, OPTIONS" };

export async function handle(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  const withCors = (r: Response) => { for (const [k, v] of Object.entries(cors)) r.headers.set(k, v); return r; };
  if (req.method !== "POST") return withCors(json({ ok: false, error: "method_not_allowed" }, 405));
  const base = Deno.env.get("SUPABASE_URL"), server = Deno.env.get("ZELLA_SERVER_SECRET_KEY"), anon = Deno.env.get("SUPABASE_ANON_KEY");
  if (!base || !server || !anon) return withCors(json({ ok: false, error: "try_again" }, 503));
  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return withCors(json({ ok: false, error: "bad_json" }, 400)); }
  const userAuth = req.headers.get("authorization") ?? "";
  const asServer = { apikey: server, Authorization: `Bearer ${server}` };
  const rpc = (fn: string, args: unknown, headers: Record<string, string>) =>
    fetch(`${base}/rest/v1/rpc/${fn}`, { method: "POST", headers: { "Content-Type": "application/json", ...headers }, body: JSON.stringify(args) });
  const removeStored = (paths: string[]) => fetch(`${base}/storage/v1/object/record-files`, {
    method: "DELETE", headers: { "Content-Type": "application/json", ...asServer }, body: JSON.stringify({ prefixes: paths }) });

  if (body.action === "check") {
    if (typeof body.file_id !== "string" || !/^[0-9a-f-]{36}$/i.test(body.file_id)) return withCors(json({ ok: false, error: "bad_request" }, 400));
    if (!/^Bearer\s+\S+/i.test(userAuth) || userAuth.includes(server)) return withCors(json({ ok: false, error: "sign_in_required" }, 401));
    // 1. as the uploader: did it arrive, and may they? (their own permissions, checked by the database)
    const fin = await rpc("zella_finish_record_file", { p_file_id: body.file_id }, { apikey: anon, Authorization: userAuth });
    if (fin.status === 401) return withCors(json({ ok: false, error: "sign_in_required" }, 401));
    if (!fin.ok) {
      const t = await fin.text();
      const code = /NOT_ALLOWED/.test(t) ? 403 : /UPLOAD_MISSING|BAD_FILE_TYPE|FILE_TOO_BIG/.test(t) ? 400 : 503;
      return withCors(json({ ok: false, error: (t.match(/NOT_ALLOWED|UPLOAD_MISSING|BAD_FILE_TYPE|FILE_TOO_BIG/) ?? ["try_again"])[0] }, code));
    }
    const f = await fin.json();
    if (f.status !== "checking") return withCors(json({ ok: f.status === "ready", status: f.status }, 200));
    // 2. the stored bytes, read with the server key
    const obj = await fetch(`${base}/storage/v1/object/record-files/${f.path}`, { headers: asServer });
    if (!obj.ok) return withCors(json({ ok: false, error: "try_again" }, 503));
    const bytes = new Uint8Array(await obj.arrayBuffer());
    const verdict = await inspect(f.mime_type, bytes);
    const reason = verdict.ok ? null : verdict.reason;
    const done = await rpc("zella_record_file_checked", { p_file_id: body.file_id, p_ok: verdict.ok, p_reason: reason, p_sha256: await sha256(bytes), p_size: bytes.length }, asServer);
    if (!done.ok) return withCors(json({ ok: false, error: "try_again" }, 503));
    if (!verdict.ok) { await removeStored([f.path]); return withCors(json({ ok: false, status: "rejected", reason }, 422)); }
    return withCors(json({ ok: true, status: "ready" }, 200));
  }

  if (body.action === "cleanup") {
    if (userAuth !== `Bearer ${server}`) return withCors(json({ ok: false, error: "server_only" }, 403));
    const list = await rpc("zella_record_file_cleanup", { p_limit: 500 }, asServer);
    if (!list.ok) return withCors(json({ ok: false, error: "try_again" }, 503));
    const paths: string[] = await list.json();
    if (paths.length) {
      const del = await removeStored(paths);
      if (!del.ok) return withCors(json({ ok: false, error: "storage_delete_failed" }, 503));
      const purged = await rpc("zella_record_files_purged", { p_paths: paths }, asServer).catch(() => null);
      if (!purged?.ok) return withCors(json({ ok: false, error: "purge_record_failed" }, 503));
    }
    return withCors(json({ ok: true, deleted: paths.length }, 200));
  }
  return withCors(json({ ok: false, error: "unknown_action" }, 400));
}

if (import.meta.main) Deno.serve(handle);
