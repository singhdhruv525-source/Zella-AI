import { assertEquals } from "jsr:@std/assert@1";
import { PAGE, runExport, type Deps } from "./logic.ts";
import { handle } from "./index.ts";

type Json = Record<string, unknown>;
type Opts = { claim?: Json | null; rows?: Record<string, number>; files?: { bucket: string; path: string }[]; failUpload?: string; finish?: string;
  download?: (bucket: string, path: string) => Promise<{ body: Uint8Array; type: string } | "missing">; deleteAfterFirstPage?: string };
function world(opts: Opts = {}) {
  const calls: { fn: string; args: Json }[] = []; const uploads: string[] = []; const progress: Json[] = [];
  const counts = opts.rows ?? { businesses: 1, calls: 2, customers: PAGE + 3 };
  // each table's rows are keyed "<table>-<0000n>", read by key after p_after, as the database does
  const data: Record<string, string[]> = Object.fromEntries(Object.entries(counts).map(([t, n]) => [t, Array.from({ length: n }, (_, i) => `${t}-${String(i).padStart(5, "0")}`)]));
  const d: Deps = {
    rpc: async (fn, args) => {
      calls.push({ fn, args });
      if (fn === "zella_export_claim") return { data: opts.claim === undefined ? { id: "job1", token: "tok", progress: {} } : opts.claim, error: null };
      if (fn === "zella_export_tables") return { data: Object.keys(counts), error: null };
      if (fn === "zella_export_rows") {
        const t = args.p_table as string, after = args.p_after as string | null;
        const page = data[t].filter((k) => after === null || k > after).slice(0, PAGE);
        if (opts.deleteAfterFirstPage === t && after === null) data[t].splice(0, 1);   // a row already read is removed
        return { data: { rows: page.map((k) => ({ k })), next: page.length === PAGE ? page.at(-1) : null }, error: null };
      }
      if (fn === "zella_export_files") return { data: opts.files ?? [{ bucket: "business-documents", path: "b1/owner_identity/a.pdf" }], error: null };
      if (fn === "zella_export_progress" || fn === "zella_export_pause") { progress.push(structuredClone(args.p_progress as Json)); return { data: true, error: null }; }
      if (fn === "zella_export_finish") return { data: args.p_ok ? (opts.finish ?? "ready") : "approved", error: null };
      return { data: null, error: { message: "unknown" } };
    },
    upload: async (path, body) => { if (opts.failUpload && path.includes(opts.failUpload)) return false; uploads.push(path); bodies[path] = String(body); return true; },
    download: opts.download ?? (async () => ({ body: new Uint8Array([1, 2, 3]), type: "application/pdf" })),
  };
  const bodies: Record<string, string> = {};
  return { d, calls, uploads, progress, bodies };
}

Deno.test("an export writes every table page by page (the business's own row too), the files and a manifest", async () => {
  const w = world();
  assertEquals(await runExport(w.d), { job: "job1", status: "ready", tables: 3, files: 1 });
  assertEquals(w.uploads, ["job1/tables/businesses/0001.json", "job1/tables/calls/0001.json", "job1/tables/customers/0001.json", "job1/tables/customers/0002.json",
    "job1/files/business-documents/b1/owner_identity/a.pdf", "job1/manifest.json"]);
  assertEquals(w.calls.filter((c) => c.fn === "zella_export_rows" && c.args.p_table === "customers").map((c) => c.args.p_after), [null, `customers-${String(PAGE - 1).padStart(5, "0")}`]);
  const last = w.progress.at(-1)!;
  assertEquals([last.tables_done, (last.counts as Json).customers, last.files_done], [["businesses", "calls", "customers"], PAGE + 3, 1]);
  assertEquals(w.calls.at(-1)!.args, { p_id: "job1", p_token: "tok", p_ok: true, p_manifest: "job1/manifest.json", p_error: null });
});

Deno.test("a row removed between pages never makes the next page skip one (pages are read by key)", async () => {
  const w = world({ rows: { customers: PAGE + 3 }, deleteAfterFirstPage: "customers" });
  assertEquals((await runExport(w.d)).status, "ready");
  const all = [...JSON.parse(w.bodies["job1/tables/customers/0001.json"]), ...JSON.parse(w.bodies["job1/tables/customers/0002.json"])].map((r: Json) => r.k);
  assertEquals(all.length, PAGE + 3);
  assertEquals(new Set(all).size, PAGE + 3);
});

Deno.test("a resumed export continues mid table from its saved key, and from its saved file list", async () => {
  const w = world({ claim: { id: "job1", token: "tok2", progress: { tables_done: ["businesses", "calls"], parts: ["job1/tables/customers/0001.json"], counts: { customers: PAGE },
      cursor: { table: "customers", after: `customers-${String(PAGE - 1).padStart(5, "0")}`, part: 1 },
      files: [{ bucket: "business-documents", path: "b1/x/old.pdf" }, { bucket: "record-files", path: "b1/r/new.png" }], files_done: 1 } },
    files: [{ bucket: "record-files", path: "b1/r/other.png" }] });   // the live list changed: the saved one is used
  assertEquals((await runExport(w.d)).status, "ready");
  assertEquals(w.uploads, ["job1/tables/customers/0002.json", "job1/files/record-files/b1/r/new.png", "job1/manifest.json"]);
  assertEquals(w.calls.some((c) => c.fn === "zella_export_files"), false);
  assertEquals((w.progress.at(-1)!.counts as Json).customers, PAGE + 3);
});

Deno.test("a file that fails to download hands the job back; one that is gone is listed in the manifest", async () => {
  const broken = world({ download: async () => { throw new Error("file read failed (503): b1/owner_identity/a.pdf"); } });
  const r = await runExport(broken.d);
  assertEquals([r.status, broken.progress.at(-1)!.files_done], ["handed_back", 0]);
  const gone = world({ download: async () => "missing" });
  assertEquals(await runExport(gone.d), { job: "job1", status: "ready", tables: 3, files: 0 });
  assertEquals(JSON.parse(gone.bodies["job1/manifest.json"]).files_gone_before_copy, ["business-documents/b1/owner_identity/a.pdf"]);
});

Deno.test("a failure hands the job back with the reason; nothing to do is quiet", async () => {
  const w = world({ failUpload: "customers" });
  const r = await runExport(w.d);
  assertEquals([r.status, r.error], ["handed_back", "customers: upload failed"]);
  const fin = w.calls.at(-1)!;
  assertEquals([fin.fn, fin.args.p_ok], ["zella_export_finish", false]);
  assertEquals((w.progress.at(-1)!.tables_done as string[]), ["businesses", "calls"]);   // resumes from here
  const none = world({ claim: null });
  assertEquals(await runExport(none.d), { job: null, status: "nothing_to_do" });
  assertEquals(none.calls.length, 1);
});

Deno.test("a run that uses up its time pauses with its progress (not a failed try), before any page read", async () => {
  let t = 0;
  const w = world();
  const r = await runExport({ ...w.d, now: () => (t += 70_000), budgetMs: 100_000 });
  assertEquals(r.status, "paused");
  assertEquals(w.calls.at(-1)!.fn, "zella_export_pause");
  assertEquals(w.calls.some((c) => c.fn === "zella_export_finish"), false);
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
