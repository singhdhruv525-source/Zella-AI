// Zella Voice: the whole business export worker (SET-DL-EXPORT part 2). sql/zella_business_export.sql holds the jobs and
// decides what may be read; this writes the export into the private business-exports bucket:
//   <job>/tables/<table>/<n>.json every row of every table that holds the business's rows, one JSON array per page
//   <job>/files/<bucket>/<path> each stored file (verification documents and files on records)
//   <job>/manifest.json         what is in the export, with row and file counts
// Progress is saved after each page, each table and every 20 files, so a run that stops resumes where it left off. Out
// of time, the job is paused (not a failed try); a failure hands it back (approved), and it ends failed after 3 tries.

type Json = Record<string, unknown>;
export type FileRef = { bucket: string; path: string };
export type Deps = {
  rpc: (fn: string, args: Json) => Promise<{ data: unknown; error: { message?: string } | null }>;
  upload: (path: string, body: string | Uint8Array, contentType: string) => Promise<boolean>;
  // "missing": the file is gone (removed since the list was taken); a failed read throws, so the run is handed back
  download: (bucket: string, path: string) => Promise<{ body: Uint8Array; type: string } | "missing">;
  now?: () => number;
  budgetMs?: number;
};
export const PAGE = 500;

export type Result = { job: string | null; status: string; tables?: number; files?: number; error?: string };
type Progress = {
  tables_done: string[]; parts: string[]; counts: Record<string, number>;
  cursor: { table: string; after: string | null; part: number } | null;   // the table being read, and where it stopped
  files: FileRef[] | null; files_done: number; missing: string[];         // the file list, taken once for the job
  tables_total: number | null;
};

export async function runExport(d: Deps): Promise<Result> {
  const now = d.now ?? Date.now, started = now(), budget = d.budgetMs ?? 120_000;
  const claimed = await d.rpc("zella_export_claim", {});
  if (claimed.error) return { job: null, status: "try_again", error: claimed.error.message };
  const c = (claimed.data ?? null) as Json | null;
  if (!c?.id) return { job: null, status: "nothing_to_do" };
  const job = String(c.id), token = String(c.token);
  const p: Progress = { tables_done: [], parts: [], counts: {}, cursor: null, files: null, files_done: 0, missing: [], tables_total: null, ...(c.progress as Json ?? {}) } as Progress;
  const save = async () => {
    const r = await d.rpc("zella_export_progress", { p_id: job, p_token: token, p_progress: p });
    if (r.error || r.data === false) throw new Error("the claim was lost");
  };
  const fail = async (message: string): Promise<Result> => {
    await d.rpc("zella_export_finish", { p_id: job, p_token: token, p_ok: false, p_manifest: null, p_error: message.slice(0, 300) });
    return { job, status: "handed_back", error: message };
  };
  // out of time: save where it stopped and hand the job back; a pause isn't a failed try (zella_export_pause)
  const pause = async (): Promise<Result> => {
    const r = await d.rpc("zella_export_pause", { p_id: job, p_token: token, p_progress: p });
    if (r.error || r.data === false) throw new Error("the claim was lost");
    return { job, status: "paused" };
  };
  const outOfTime = () => now() - started > budget;
  try {
    const t = await d.rpc("zella_export_tables", {});
    if (t.error) throw new Error(t.error.message ?? "tables");
    const tables = (t.data as string[]) ?? [];
    p.tables_total = tables.length;
    for (const table of tables) {
      if (p.tables_done.includes(table)) continue;
      // each page is its own part (tables/<table>/<n>.json), saved as it is written, so a large table resumes mid way
      const at = p.cursor?.table === table ? p.cursor : { table, after: null, part: 0 };
      p.cursor = at;
      for (;;) {
        if (outOfTime()) return await pause();
        const r = await d.rpc("zella_export_rows", { p_id: job, p_token: token, p_table: table, p_after: at.after, p_limit: PAGE });
        if (r.error) throw new Error(`${table}: ${r.error.message ?? "read failed"}`);
        const page = r.data as { rows?: unknown[]; next?: string | null } | null;
        const rows = Array.isArray(page?.rows) ? page.rows : null;
        if (!rows) throw new Error(`${table}: the read answered nothing`);
        if (rows.length || at.part === 0) {
          const path = `${job}/tables/${table}/${String(at.part + 1).padStart(4, "0")}.json`;
          if (!(await d.upload(path, JSON.stringify(rows), "application/json"))) throw new Error(`${table}: upload failed`);
          if (!p.parts.includes(path)) p.parts.push(path);
          p.counts[table] = (p.counts[table] ?? 0) + rows.length;
          at.part += 1;
        }
        at.after = typeof page?.next === "string" ? page.next : null;
        if (!at.after) break;
        await save();
      }
      p.tables_done.push(table); p.cursor = null;
      await save();
    }
    // the file list is taken once for the job and kept in its progress, so files removed or added later never shift it
    if (!p.files) {
      const f = await d.rpc("zella_export_files", { p_id: job, p_token: token });
      if (f.error || !Array.isArray(f.data)) throw new Error(f.error?.message ?? "files");
      p.files = f.data as FileRef[]; p.files_done = 0;
      await save();
    }
    for (let i = p.files_done; i < p.files.length; i++) {
      if (outOfTime()) return await pause();
      const { bucket, path } = p.files[i];
      const got = await d.download(bucket, path);
      if (got === "missing") { if (!p.missing.includes(`${bucket}/${path}`)) p.missing.push(`${bucket}/${path}`); }
      else {
        const to = `${job}/files/${bucket}/${path}`;
        if (!(await d.upload(to, got.body, got.type || "application/octet-stream"))) throw new Error(`file upload failed: ${path}`);
        if (!p.parts.includes(to)) p.parts.push(to);
      }
      p.files_done = i + 1;
      if (p.files_done % 20 === 0) await save();
    }
    await save();
    const manifest = { job, made_at: new Date(now()).toISOString(), tables: p.counts, files: p.parts.filter((x) => x.includes("/files/")).length,
      files_gone_before_copy: p.missing,
      left_out: "integration_secrets, crm_record_secrets, email_unsubscribe_tokens, secret columns, call recording links, and call transcripts and summaries in sensitive industries" };
    const manifestPath = `${job}/manifest.json`;
    if (!(await d.upload(manifestPath, JSON.stringify(manifest, null, 2), "application/json"))) throw new Error("manifest upload failed");
    const done = await d.rpc("zella_export_finish", { p_id: job, p_token: token, p_ok: true, p_manifest: manifestPath, p_error: null });
    if (done.error || done.data !== "ready") throw new Error("finish was refused");
    return { job, status: "ready", tables: p.tables_done.length, files: p.files_done - p.missing.length };
  } catch (e) {
    return await fail(e instanceof Error ? e.message : String(e));
  }
}
