// Zella Voice: the whole business export worker (SET-DL-EXPORT part 2). sql/zella_business_export.sql holds the jobs and
// decides what may be read; this writes the export into the private business-exports bucket:
//   <job>/tables/<table>.json   every row of every table that holds the business's rows (one JSON array per table)
//   <job>/files/<bucket>/<path> each stored file (verification documents and files on records)
//   <job>/manifest.json         what is in the export, with row and file counts
// Progress is saved after each table and every 20 files, so a run that stops resumes where it left off. A failure hands
// the job back (approved), and the database ends it failed after 3 tries.

type Json = Record<string, unknown>;
export type Deps = {
  rpc: (fn: string, args: Json) => Promise<{ data: unknown; error: { message?: string } | null }>;
  upload: (path: string, body: string | Uint8Array, contentType: string) => Promise<boolean>;
  download: (bucket: string, path: string) => Promise<{ body: Uint8Array; type: string } | null>;
  now?: () => number;
  budgetMs?: number;
};
export const PAGE = 500;

export type Result = { job: string | null; status: string; tables?: number; files?: number; error?: string };

export async function runExport(d: Deps): Promise<Result> {
  const now = d.now ?? Date.now, started = now(), budget = d.budgetMs ?? 120_000;
  const claimed = await d.rpc("zella_export_claim", {});
  if (claimed.error) return { job: null, status: "try_again", error: claimed.error.message };
  const c = (claimed.data ?? null) as Json | null;
  if (!c?.id) return { job: null, status: "nothing_to_do" };
  const job = String(c.id), token = String(c.token);
  const p = { tables_done: [] as string[], parts: [] as string[], counts: {} as Record<string, number>, files_done: 0, files_total: null as number | null, tables_total: null as number | null, ...(c.progress as Json ?? {}) } as {
    tables_done: string[]; parts: string[]; counts: Record<string, number>; files_done: number; files_total: number | null; tables_total: number | null };
  const save = async () => {
    const r = await d.rpc("zella_export_progress", { p_id: job, p_token: token, p_progress: p });
    if (r.error || r.data === false) throw new Error("the claim was lost");
  };
  const fail = async (message: string): Promise<Result> => {
    await d.rpc("zella_export_finish", { p_id: job, p_token: token, p_ok: false, p_manifest: null, p_error: message.slice(0, 300) });
    return { job, status: "handed_back", error: message };
  };
  try {
    const t = await d.rpc("zella_export_tables", {});
    if (t.error) throw new Error(t.error.message ?? "tables");
    const tables = (t.data as string[]) ?? [];
    p.tables_total = tables.length;
    for (const table of tables) {
      if (p.tables_done.includes(table)) continue;
      if (now() - started > budget) return await fail("paused: it continues on the next run");
      const rows: unknown[] = [];
      for (let offset = 0; ; offset += PAGE) {
        const r = await d.rpc("zella_export_rows", { p_id: job, p_token: token, p_table: table, p_offset: offset, p_limit: PAGE });
        if (r.error) throw new Error(`${table}: ${r.error.message ?? "read failed"}`);
        const page = (r.data as unknown[]) ?? [];
        rows.push(...page);
        if (page.length < PAGE) break;
      }
      const path = `${job}/tables/${table}.json`;
      if (!(await d.upload(path, JSON.stringify(rows), "application/json"))) throw new Error(`${table}: upload failed`);
      p.tables_done.push(table); p.counts[table] = rows.length;
      if (!p.parts.includes(path)) p.parts.push(path);
      await save();
    }
    const f = await d.rpc("zella_export_files", { p_id: job, p_token: token });
    if (f.error) throw new Error(f.error.message ?? "files");
    const files = ((f.data as { bucket: string; path: string }[]) ?? []);
    p.files_total = files.length;
    for (let i = p.files_done; i < files.length; i++) {
      if (now() - started > budget) { await save(); return await fail("paused: it continues on the next run"); }
      const { bucket, path } = files[i];
      const got = await d.download(bucket, path);
      if (got) {
        const to = `${job}/files/${bucket}/${path}`;
        if (!(await d.upload(to, got.body, got.type || "application/octet-stream"))) throw new Error(`file upload failed: ${path}`);
        if (!p.parts.includes(to)) p.parts.push(to);
      }
      p.files_done = i + 1;
      if (p.files_done % 20 === 0) await save();
    }
    await save();
    const manifest = { job, made_at: new Date(now()).toISOString(), tables: p.counts, files: p.parts.filter((x) => x.includes("/files/")).length,
      left_out: "integration_secrets, crm_record_secrets, email_unsubscribe_tokens, secret columns, call recording links, and call transcripts and summaries in sensitive industries" };
    const manifestPath = `${job}/manifest.json`;
    if (!(await d.upload(manifestPath, JSON.stringify(manifest, null, 2), "application/json"))) throw new Error("manifest upload failed");
    const done = await d.rpc("zella_export_finish", { p_id: job, p_token: token, p_ok: true, p_manifest: manifestPath, p_error: null });
    if (done.error || done.data !== "ready") throw new Error("finish was refused");
    return { job, status: "ready", tables: p.tables_done.length, files: p.files_done };
  } catch (e) {
    return await fail(e instanceof Error ? e.message : String(e));
  }
}
