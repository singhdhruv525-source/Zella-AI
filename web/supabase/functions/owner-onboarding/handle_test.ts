// The owner-onboarding function with the database and storage mocked: who may call it (the owner of another business,
// a staff member and anonymous are refused, and nothing is stored for them), what each step sends, and what the owner
// is told. The database's own checks are tested in tests/owner_onboarding/run.sh.
import { assert, assertEquals } from "jsr:@std/assert@1";
import { handle } from "./index.ts";

Deno.env.set("SUPABASE_URL", "http://db.test");
Deno.env.set("ZELLA_SERVER_SECRET_KEY", "server-key");
Deno.env.set("SUPABASE_ANON_KEY", "anon-key");
const realFetch = globalThis.fetch;
const BIZ = "6f1c0c1e-0000-4000-8000-000000000001";
const OWNER = "a0b00000-0000-4000-8000-000000000001";
type Call = { url: string; method: string; headers: Record<string, string>; body: string };
const j = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status });
// The database, as each token's owner would see it (the real rules live in the SQL; this stands in for its answers).
const people: Record<string, Response | (() => Response)> = {
  "Bearer owner-jwt": () => j({ ok: true, user_id: OWNER }),
  "Bearer other-owner-jwt": () => j({ code: "P0001", message: "NOT_ALLOWED", details: null }, 400),
  "Bearer staff-jwt": () => j({ code: "P0001", message: "NOT_ALLOWED", details: null }, 400),
  "Bearer aal1-jwt": () => j({ code: "P0001", message: "MFA_REQUIRED", details: null }, 400),
  "Bearer done-jwt": () => j({ code: "P0001", message: "UPLOAD_NOT_ALLOWED", details: null }, 400),
  "Bearer expired-jwt": () => j({ code: "PGRST301", message: "JWT expired" }, 401),
};
let stored: { name: string; metadata: { size: number; mimetype: string } }[] = [];
const JPEG = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0, 16, 0x4a, 0x46, 0x49, 0x46, 0, 1, 1, 0, 0, 1]);
let content: Uint8Array = JPEG;
function backend(c: Call): Response {
  if (c.url.endsWith("/rpc/zella_owner_identity_upload_check")) {
    const who = people[c.headers.Authorization];
    return typeof who === "function" ? who() : j({ message: "JWT invalid" }, 401);
  }
  if (c.url.startsWith(`http://db.test/storage/v1/object/upload/sign/business-documents/${BIZ}/`)) {
    return j({ url: `/object/upload/sign/business-documents/x?token=signed-token` });
  }
  if (c.url === "http://db.test/storage/v1/object/list/business-documents") return j(stored);
  if (c.url.startsWith(`http://db.test/storage/v1/object/business-documents/${BIZ}/`) && c.method === "GET") return new Response(new Blob([new Uint8Array(content)]));
  if (c.url.endsWith("/rpc/zella_owner_identity_document_add")) {
    return j({ document: { kind: "owner_identity", status: "pending_review", review_note: null, uploaded_at: "2026-11-16T15:10:00Z", reviewed_at: null },
               identity: { status: "checking" } });
  }
  return j({ message: "not mocked" }, 404);
}
function mock(fn: (calls: Call[]) => Promise<void>, routes = backend) {
  return async () => {
    const calls: Call[] = [];
    globalThis.fetch = (async (url: string, init: RequestInit = {}) => {
      const c = { url, method: init.method ?? "GET", headers: (init.headers ?? {}) as Record<string, string>, body: typeof init.body === "string" ? init.body : "" };
      calls.push(c); return routes(c);
    }) as typeof fetch;
    try { await fn(calls); } finally { globalThis.fetch = realFetch; stored = []; content = JPEG; }
  };
}
const send = (body: unknown, auth?: string, extra: Record<string, string> = {}) => handle(new Request("http://fn/owner-onboarding", {
  method: "POST", body: typeof body === "string" ? body : JSON.stringify(body),
  headers: { "content-type": "application/json", ...(auth ? { authorization: auth } : {}), ...extra } }));
const upload = { action: "identity_upload_url", businessId: BIZ, kind: "owner_identity", fileName: "passport.jpg", mimeType: "image/jpeg", size: 2048 };
const touchedServer = (calls: Call[]) => calls.some((c) => c.headers.Authorization === "Bearer server-key");

Deno.test("the owner gets an upload link for a path the function chose, after the database check with their own session", mock(async (calls) => {
  const r = await send(upload, "Bearer owner-jwt");
  assertEquals(r.status, 200);
  const out = await r.json();
  assertEquals(out.token, "signed-token");
  assert(new RegExp(`^${BIZ}/owner_identity/[0-9a-f-]{36}\\.jpg$`).test(out.path), out.path);
  assertEquals(calls[0].headers.Authorization, "Bearer owner-jwt");   // the owner's own permissions
  assertEquals(calls[0].headers.apikey, "anon-key");
  assertEquals(JSON.parse(calls[0].body), { p_business_id: BIZ, p_kind: "owner_identity" });
  assertEquals(calls[1].headers.Authorization, "Bearer server-key");  // only the link itself needs the server key
  assertEquals(calls.length, 2);
}));

for (const [who, auth, status, code] of [
  ["the owner of another business", "Bearer other-owner-jwt", 403, "NOT_ALLOWED"],
  ["a staff member", "Bearer staff-jwt", 403, "NOT_ALLOWED"],
  ["a session without the authenticator code", "Bearer aal1-jwt", 403, "MFA_REQUIRED"],
  ["an owner whose documents are already in", "Bearer done-jwt", 409, "UPLOAD_NOT_ALLOWED"],
  ["an expired session", "Bearer expired-jwt", 401, "NOT_SIGNED_IN"],
] as const) {
  for (const action of ["identity_upload_url", "identity_upload_confirm"]) {
    Deno.test(`${action}: ${who} is refused and nothing is signed or stored`, mock(async (calls) => {
      const r = await send({ ...upload, action, path: `${BIZ}/owner_identity/11111111-2222-4333-8444-555555555555.jpg` }, auth);
      assertEquals(r.status, status);
      const out = await r.json();
      assertEquals(out.code, code);
      assert(!/[-–—]/.test(out.error), out.error);   // no dashes in words the owner sees
      assertEquals(touchedServer(calls), false);
    }));
  }
}

Deno.test("anonymous callers are refused before anything is called", mock(async (calls) => {
  for (const auth of [undefined, "Bearer anon-key", "Bearer server-key", "Basic abc", "Bearer "]) {
    const r = await send(upload, auth);
    assertEquals(r.status, 401, String(auth));
    assertEquals((await r.json()).code, "NOT_SIGNED_IN");
  }
  assertEquals(calls.length, 0);
}));

Deno.test("bad input is refused with plain words, before the database", mock(async (calls) => {
  const cases: [Record<string, unknown>, string][] = [
    [{ ...upload, businessId: "not-a-uuid" }, "That didn't work. Reload the page and try again."],
    [{ ...upload, kind: "tax_registration" }, "That didn't work. Reload the page and try again."],
    [{ ...upload, mimeType: "image/gif" }, "Upload a PDF, JPG, PNG, WEBP or HEIC file."],
    [{ ...upload, size: 10 * 1024 * 1024 + 1 }, "The file is over 10 MB. Upload a smaller copy."],
    [{ ...upload, size: 0 }, "That didn't work. Reload the page and try again."],
    [{ ...upload, fileName: "" }, "Give the file a shorter name and try again."],
    [{ ...upload, action: "document_review" }, "That didn't work. Reload the page and try again."],
  ];
  for (const [body, words] of cases) {
    const r = await send(body, "Bearer owner-jwt");
    assertEquals(r.status, 400, JSON.stringify(body));
    assertEquals((await r.json()).error, words);
  }
  assertEquals((await send("{not json", "Bearer owner-jwt")).status, 400);
  assertEquals((await send({ ...upload, pad: "x".repeat(20_000) }, "Bearer owner-jwt")).status, 413);
  assertEquals(calls.length, 0);
}));

Deno.test("confirm records the stored file with the owner's id from the database, never from the request", mock(async (calls) => {
  const path = `${BIZ}/owner_identity/11111111-2222-4333-8444-555555555555.jpg`;
  stored = [{ name: "11111111-2222-4333-8444-555555555555.jpg", metadata: { size: 2048, mimetype: "image/jpeg" } }];
  const r = await send({ ...upload, action: "identity_upload_confirm", path, userId: "a0b00000-0000-4000-8000-000000000999" }, "Bearer owner-jwt");
  assertEquals(r.status, 200);
  assertEquals((await r.json()).document.status, "pending_review");
  const add = calls.find((c) => c.url.endsWith("zella_owner_identity_document_add"))!;
  assertEquals(add.headers.Authorization, "Bearer server-key");
  assertEquals(JSON.parse(add.body), { p_business_id: BIZ, p_user: OWNER, p_kind: "owner_identity", p_path: path,
    p_file_name: "passport.jpg", p_mime: "image/jpeg", p_size: 2048 });
}));

Deno.test("confirm refuses another business's path, a missing file and a file that doesn't match", mock(async (calls) => {
  const other = "6f1c0c1e-0000-4000-8000-000000000002";
  for (const path of [`${other}/owner_identity/11111111-2222-4333-8444-555555555555.jpg`, `${BIZ}/business_registration/11111111-2222-4333-8444-555555555555.jpg`,
                      `${BIZ}/owner_identity/11111111-2222-4333-8444-555555555555.pdf`, `${BIZ}/owner_identity/../x.jpg`]) {
    const r = await send({ ...upload, action: "identity_upload_confirm", path }, "Bearer owner-jwt");
    assertEquals(r.status, 400, path);
  }
  const path = `${BIZ}/owner_identity/11111111-2222-4333-8444-555555555555.jpg`;
  let r = await send({ ...upload, action: "identity_upload_confirm", path }, "Bearer owner-jwt");
  assertEquals([r.status, (await r.json()).error], [400, "The file didn't finish uploading. Try again."]);
  stored = [{ name: "11111111-2222-4333-8444-555555555555.jpg", metadata: { size: 999, mimetype: "image/jpeg" } }];
  r = await send({ ...upload, action: "identity_upload_confirm", path }, "Bearer owner-jwt");
  assertEquals([r.status, (await r.json()).error], [400, "The file didn't upload correctly. Try again."]);
  assertEquals(calls.some((c) => c.url.endsWith("zella_owner_identity_document_add")), false);
}));

Deno.test("confirm checks the file's own bytes, and a storage failure is never read as a missing file", mock(async (calls) => {
  const path = `${BIZ}/owner_identity/11111111-2222-4333-8444-555555555555.jpg`;
  stored = [{ name: "11111111-2222-4333-8444-555555555555.jpg", metadata: { size: 2048, mimetype: "image/jpeg" } }];
  content = new TextEncoder().encode("MZ not a photo at all");
  let r = await send({ ...upload, action: "identity_upload_confirm", path }, "Bearer owner-jwt");
  assertEquals([r.status, (await r.json()).code], [400, "INVALID_INPUT"]);
  const read = calls.find((c) => c.url.endsWith(path) && c.method === "GET")!;
  assertEquals([read.headers.Authorization, read.headers.Range], ["Bearer server-key", "bytes=0-15"]);
  assertEquals(calls.some((c) => c.url.endsWith("zella_owner_identity_document_add")), false);
}));

Deno.test("storage answering 503 to the file list is SERVER_ERROR, not \"didn't finish uploading\"", mock(async () => {
  const path = `${BIZ}/owner_identity/11111111-2222-4333-8444-555555555555.jpg`;
  const r = await send({ ...upload, action: "identity_upload_confirm", path }, "Bearer owner-jwt");
  assertEquals([r.status, (await r.json()).code], [500, "SERVER_ERROR"]);
}, (c) => c.url.endsWith("/object/list/business-documents") ? j({ message: "unavailable" }, 503) : backend(c)));

Deno.test("a failure on the server side is SERVER_ERROR, never a raw database message", mock(async () => {
  const r = await send(upload, "Bearer owner-jwt");
  assertEquals(r.status, 500);
  const out = await r.json();
  assertEquals(out.code, "SERVER_ERROR");
  assert(!JSON.stringify(out).includes("relation"));
}, (c) => c.url.endsWith("upload_check") ? j({ code: "42P01", message: "relation \"x\" does not exist" }, 404) : j({}, 500)));

Deno.test("a network failure or timeout answers SERVER_ERROR", mock(async () => {
  const r = await send(upload, "Bearer owner-jwt");
  assertEquals([r.status, (await r.json()).code], [500, "SERVER_ERROR"]);
}, () => { throw new TypeError("network down"); }));

Deno.test("browser preflight and CORS: only allowed origins get the answer", mock(async () => {
  const pre = await handle(new Request("http://fn/owner-onboarding", { method: "OPTIONS", headers: { origin: "http://localhost:5199" } }));
  assertEquals(pre.headers.get("access-control-allow-origin"), "http://localhost:5199");
  const r = await send(upload, "Bearer owner-jwt", { origin: "https://evil.example" });
  assertEquals(r.headers.get("access-control-allow-origin"), null);
}));
