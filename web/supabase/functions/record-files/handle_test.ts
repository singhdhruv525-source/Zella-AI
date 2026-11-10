// The record-files function with the database and storage mocked: who can call it, what it does with each verdict.
import { assertEquals } from "jsr:@std/assert@1";
import { handle } from "./index.ts";

Deno.env.set("SUPABASE_URL", "http://db.test");
Deno.env.set("ZELLA_SERVER_SECRET_KEY", "server-key");
Deno.env.set("SUPABASE_ANON_KEY", "anon-key");
const realFetch = globalThis.fetch;
const ID = "11111111-2222-3333-4444-555555555555";
const PNG = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3]);
type Call = { url: string; method: string; headers: Record<string, string>; body: string };
function mock(routes: (c: Call) => Response, fn: (calls: Call[]) => Promise<void>) {
  return async () => {
    const calls: Call[] = [];
    globalThis.fetch = (async (url: string, init: RequestInit = {}) => {
      const c = { url, method: init.method ?? "GET", headers: (init.headers ?? {}) as Record<string, string>, body: typeof init.body === "string" ? init.body : "" };
      calls.push(c); return routes(c);
    }) as typeof fetch;
    try { await fn(calls); } finally { globalThis.fetch = realFetch; }
  };
}
const j = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status });
const call = (body: unknown, auth?: string) => handle(new Request("http://fn/record-files", { method: "POST", body: JSON.stringify(body),
  headers: { "content-type": "application/json", ...(auth ? { authorization: auth } : {}) } }));
const finished = (mime = "image/png") => j({ id: ID, status: "checking", path: "b/r/f.png", mime_type: mime, size_bytes: 11 });
function storage(bytes: Uint8Array) {
  return (c: Call) => c.url.endsWith("zella_finish_record_file") ? finished()
    : c.url.startsWith("http://db.test/storage/v1/object/record-files/") && c.method === "GET" ? new Response(bytes as Uint8Array<ArrayBuffer>)
    : c.url.endsWith("zella_record_file_checked") ? j({ ok: true })
    : c.method === "DELETE" ? j([]) : j({}, 404);
}

Deno.test("a real PNG: finished as the uploader, read and judged as the server, ready", mock(storage(PNG), async (calls) => {
  const r = await call({ action: "check", file_id: ID }, "Bearer user-jwt");
  assertEquals(r.status, 200); assertEquals(await r.json(), { ok: true, status: "ready" });
  assertEquals(calls[0].headers.Authorization, "Bearer user-jwt"); // the uploader's own permissions
  assertEquals(calls[0].headers.apikey, "anon-key");
  assertEquals(calls[1].headers.Authorization, "Bearer server-key");
  const v = JSON.parse(calls[2].body); assertEquals([v.p_ok, v.p_size, v.p_sha256.length], [true, 11, 64]);
  assertEquals(calls.some((c) => c.method === "DELETE"), false);
}));
Deno.test("a script renamed .png: rejected, verdict recorded, stored copy deleted", mock(storage(new TextEncoder().encode("<script>x</script>")), async (calls) => {
  const r = await call({ action: "check", file_id: ID }, "Bearer user-jwt");
  assertEquals(r.status, 422); assertEquals((await r.json()).status, "rejected");
  assertEquals(JSON.parse(calls[2].body).p_ok, false);
  const del = calls.find((c) => c.method === "DELETE")!; assertEquals(JSON.parse(del.body), { prefixes: ["b/r/f.png"] });
  assertEquals(del.headers.Authorization, "Bearer server-key");
}));
Deno.test("not signed in, or presenting the server key as a user: refused before anything", mock(() => j({}), async (calls) => {
  assertEquals((await call({ action: "check", file_id: ID })).status, 401);
  assertEquals((await call({ action: "check", file_id: ID }, "Bearer server-key")).status, 401);
  assertEquals(calls.length, 0);
}));
Deno.test("someone else's file (database says no): 403, nothing read", mock((c) => c.url.endsWith("zella_finish_record_file") ? j({ message: "NOT_ALLOWED" }, 400) : j({}, 500), async (calls) => {
  const r = await call({ action: "check", file_id: ID }, "Bearer other-user");
  assertEquals(r.status, 403); assertEquals(calls.length, 1);
}));
Deno.test("expired or forged sign-in (the database refuses the token): 401", mock(() => j({ message: "JWT expired" }, 401), async (calls) => {
  assertEquals((await call({ action: "check", file_id: ID }, "Bearer forged")).status, 401); assertEquals(calls.length, 1);
}));
Deno.test("upload never arrived: 400", mock((c) => j({ message: "UPLOAD_MISSING" }, 400), async () => {
  assertEquals((await call({ action: "check", file_id: ID }, "Bearer u")).status, 400);
}));
Deno.test("already judged: answers with its status, no second check", mock(() => j({ id: ID, status: "ready" }), async (calls) => {
  const r = await call({ action: "check", file_id: ID }, "Bearer u");
  assertEquals(await r.json(), { ok: true, status: "ready" }); assertEquals(calls.length, 1);
}));
Deno.test("storage unreachable: 503 and the file stays checking (retry later)", mock((c) => c.url.endsWith("zella_finish_record_file") ? finished() : j({}, 500), async (calls) => {
  assertEquals((await call({ action: "check", file_id: ID }, "Bearer u")).status, 503);
  assertEquals(calls.some((c) => c.url.endsWith("zella_record_file_checked")), false);
}));
Deno.test("bad requests", mock(() => j({}), async () => {
  assertEquals((await call({ action: "check", file_id: "x" }, "Bearer u")).status, 400);
  assertEquals((await call({ action: "nope" }, "Bearer u")).status, 400);
  assertEquals((await handle(new Request("http://fn/record-files", { method: "GET" }))).status, 405);
  assertEquals((await handle(new Request("http://fn/record-files", { method: "POST", body: "{" }))).status, 400);
}));
Deno.test("cleanup: server only; deletes listed objects then records them purged", mock((c) =>
  c.url.endsWith("zella_record_file_cleanup") ? j(["b/r/old.pdf", "b/r/orphan.png"]) : c.method === "DELETE" ? j([]) : j(null), async (calls) => {
  assertEquals((await call({ action: "cleanup" }, "Bearer user-jwt")).status, 403);
  assertEquals(calls.length, 0);
  const r = await call({ action: "cleanup" }, "Bearer server-key");
  assertEquals(await r.json(), { ok: true, deleted: 2 });
  assertEquals(calls.map((c) => c.url.split("/").pop()), ["zella_record_file_cleanup", "record-files", "zella_record_files_purged"]);
  assertEquals(JSON.parse(calls[2].body).p_paths, ["b/r/old.pdf", "b/r/orphan.png"]);
}));
Deno.test("cleanup: storage delete fails, nothing marked purged (next run retries)", mock((c) =>
  c.url.endsWith("zella_record_file_cleanup") ? j(["b/r/old.pdf"]) : c.method === "DELETE" ? j({}, 500) : j(null), async (calls) => {
  assertEquals((await call({ action: "cleanup" }, "Bearer server-key")).status, 503);
  assertEquals(calls.some((c) => c.url.endsWith("zella_record_files_purged")), false);
}));

Deno.test("cleanup: purge record failure is distinct and retryable", mock((c) =>
  c.url.endsWith("zella_record_file_cleanup") ? j(["b/r/old.pdf"]) : c.method === "DELETE" ? j([]) : j({}, 500), async () => {
  const r = await call({ action: "cleanup" }, "Bearer server-key");
  assertEquals(r.status, 503);
  assertEquals(await r.json(), { ok: false, error: "purge_record_failed" });
}));
