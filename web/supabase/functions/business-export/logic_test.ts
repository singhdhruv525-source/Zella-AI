import { assertEquals } from "jsr:@std/assert@1";
import { PAGE, runExport, type Deps } from "./logic.ts";
import { handle } from "./index.ts";

type Json = Record<string, unknown>;
function world(opts: { claim?: Json | null; rows?: Record<string, number>; files?: { bucket: string; path: string }[]; failUpload?: string; finish?: string } = {}) {
  const calls: { fn: string; args: Json }[] = []; const uploads: string[] = []; const progress: Json[] = [];
  const rows = opts.rows ?? { calls: 2, customers: PAGE + 3 };
  const d: Deps = {
    rpc: async (fn, args) => {
      calls.push({ fn, args });
      if (fn === "zella_export_claim") return { data: opts.claim === undefined ? { id: "job1", token: "tok", progress: {} } : opts.claim, error: null };
      if (fn === "zella_export_tables") return { data: Object.keys(rows), error: null };
      if (fn === "zella_export_rows") {
        const n = rows[args.p_table as string]; const off = args.p_offset as number;
        return { data: Array.from({ length: Math.max(0, Math.min(PAGE, n - off)) }, (_, i) => ({ i: off + i })), error: null };
      }
      if (fn === "zella_export_files") return { data: opts.files ?? [{ bucket: "business-documents", path: "b1/owner_identity/a.pdf" }], error: null };
      if (fn === "zella_export_progress") { progress.push(structuredClone(args.p_progress as Json)); return { data: true, error: null }; }
      if (fn === "zella_export_finish") return { data: args.p_ok ? (opts.finish ?? "ready") : "approved", error: null };
      return { data: null, error: { message: "unknown" } };
    },
    upload: async (path) => { if (opts.failUpload && path.includes(opts.failUpload)) return false; uploads.push(path); return true; },
    download: async () => ({ body: new Uint8Array([1, 2, 3]), type: "application/pdf" }),
  };
  return { d, calls, uploads, progress };
}

Deno.test("an export writes every table (all pages), the files and a manifest, then finishes ready", async () => {
  const w = world();
  assertEquals(await runExport(w.d), { job: "job1", status: "ready", tables: 2, files: 1 });
  assertEquals(w.uploads, ["job1/tables/calls.json", "job1/tables/customers.json", "job1/files/business-documents/b1/owner_identity/a.pdf", "job1/manifest.json"]);
  assertEquals(w.calls.filter((c) => c.fn === "zella_export_rows" && c.args.p_table === "customers").map((c) => c.args.p_offset), [0, PAGE]);
  const last = w.progress.at(-1)!;
  assertEquals([last.tables_done, (last.counts as Json).customers, last.files_done], [["calls", "customers"], PAGE + 3, 1]);
  assertEquals(w.calls.at(-1)!.args, { p_id: "job1", p_token: "tok", p_ok: true, p_manifest: "job1/manifest.json", p_error: null });
});

Deno.test("a resumed export skips the tables and files already done", async () => {
  const w = world({ claim: { id: "job1", token: "tok2", progress: { tables_done: ["calls"], parts: ["job1/tables/calls.json"], counts: { calls: 2 }, files_done: 1 } },
    files: [{ bucket: "business-documents", path: "b1/x/old.pdf" }, { bucket: "record-files", path: "b1/r/new.png" }] });
  assertEquals((await runExport(w.d)).status, "ready");
  assertEquals(w.uploads, ["job1/tables/customers.json", "job1/files/record-files/b1/r/new.png", "job1/manifest.json"]);
  assertEquals(w.calls.some((c) => c.fn === "zella_export_rows" && c.args.p_table === "calls"), false);
});

Deno.test("a failure hands the job back with the reason; nothing to do is quiet", async () => {
  const w = world({ failUpload: "customers" });
  const r = await runExport(w.d);
  assertEquals([r.status, r.error], ["handed_back", "customers: upload failed"]);
  const fin = w.calls.at(-1)!;
  assertEquals([fin.fn, fin.args.p_ok], ["zella_export_finish", false]);
  assertEquals((w.progress.at(-1)!.tables_done as string[]), ["calls"]);   // resumes from here
  const none = world({ claim: null });
  assertEquals(await runExport(none.d), { job: null, status: "nothing_to_do" });
  assertEquals(none.calls.length, 1);
});

Deno.test("a run that uses up its time saves progress and hands the job back to continue", async () => {
  let t = 0;
  const w = world();
  const r = await runExport({ ...w.d, now: () => (t += 70_000), budgetMs: 100_000 });
  assertEquals(r.status, "handed_back");
  assertEquals(w.uploads.includes("job1/manifest.json"), false);
});

Deno.test("the worker answers only the server key", async () => {
  Deno.env.set("SUPABASE_URL", "http://db.test"); Deno.env.set("ZELLA_SERVER_SECRET_KEY", "server-key");
  const real = globalThis.fetch; let called = 0;
  globalThis.fetch = (async () => { called++; return new Response("null"); }) as typeof fetch;
  try {
    for (const auth of [undefined, "Bearer user-jwt", "Bearer anon-key"]) {
      const r = await handle(new Request("http://fn/business-export", { method: "POST", headers: auth ? { authorization: auth } : {} }));
      assertEquals(r.status, 403);
    }
    assertEquals(called, 0);
    const ok = await handle(new Request("http://fn/business-export", { method: "POST", headers: { authorization: "Bearer server-key" } }));
    assertEquals(await ok.json(), { ok: true, job: null, status: "nothing_to_do" });
    assertEquals((await handle(new Request("http://fn/business-export", { method: "GET" }))).status, 405);
  } finally { globalThis.fetch = real; }
});
