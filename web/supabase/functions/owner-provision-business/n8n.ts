// n8n's own view of the Zella Voice workflows (AUTO-N8N-STATUS): whether each is active in n8n, and its last
// execution. Read with n8n's public API and a key kept as a server secret (N8N_API_KEY, with the instance address in
// N8N_API_URL). The key and the address are never returned. Read only: nothing is activated or run.
// Until the owner creates the key and sets both secrets, the answer is { configured: false } ("Not connected yet").

export type FetchLike = (url: string, init: RequestInit) => Promise<Response>;
export type N8nWorkflow = { id: string; name: string; active: boolean; lastExecution: { status: string; startedAt: string | null; stoppedAt: string | null } | null };
export type N8nStatus =
  | { configured: false }
  | { configured: true; ok: false; error: string }
  | { configured: true; ok: true; workflows: N8nWorkflow[]; checkedAt: string };

export const N8N_TIMEOUT_MS = 5000;
const PAGE = 250;

// "Zella Voice - Follow-up Texts" -> "Follow up Texts": plain words, no dashes on screen
export const workflowLabel = (name: string) => name.replace(/^Zella(\s+Voice)?\s*[-:]\s*/i, "").replace(/[-‐–—]+/g, " ").replace(/\s+/g, " ").trim();
const isZella = (name: unknown) => typeof name === "string" && /^zella/i.test(name.trim());

export async function n8nStatus(env: (name: string) => string | undefined, fetchImpl: FetchLike = fetch): Promise<N8nStatus> {
  const key = env("N8N_API_KEY")?.trim();
  const base = env("N8N_API_URL")?.trim().replace(/\/+$/, "");
  if (!key || !base) return { configured: false };
  if (!/^https:\/\//i.test(base)) return { configured: true, ok: false, error: "The n8n address must start with https://" };
  const get = async (path: string) => {
    let res: Response;
    try {
      res = await fetchImpl(`${base}/api/v1/${path}`, { headers: { "X-N8N-API-KEY": key, accept: "application/json" }, signal: AbortSignal.timeout(N8N_TIMEOUT_MS) });
    } catch {
      throw new Error("Couldn't reach n8n");
    }
    if (res.status === 401 || res.status === 403) throw new Error("n8n refused the key");
    if (!res.ok) throw new Error(`n8n answered ${res.status}`);
    try { return await res.json(); } catch { throw new Error("n8n sent an answer that isn't readable"); }
  };
  try {
    const [wf, ex] = await Promise.all([get(`workflows?limit=${PAGE}`), get(`executions?limit=${PAGE}`)]);
    const last = new Map<string, N8nWorkflow["lastExecution"]>();
    // executions come newest first; keep the first one seen per workflow
    for (const e of Array.isArray(ex?.data) ? ex.data : []) {
      const id = String(e?.workflowId ?? "");
      if (!id || last.has(id)) continue;
      const status = typeof e?.status === "string" ? e.status : e?.finished === true ? "success" : e?.stoppedAt ? "error" : "running";
      last.set(id, { status, startedAt: e?.startedAt ?? null, stoppedAt: e?.stoppedAt ?? null });
    }
    const workflows = (Array.isArray(wf?.data) ? wf.data : [])
      .filter((w: { name?: unknown }) => isZella(w?.name))
      .map((w: { id: unknown; name: string; active: unknown }) => ({ id: String(w.id), name: workflowLabel(w.name), active: w.active === true, lastExecution: last.get(String(w.id)) ?? null }))
      .sort((a: N8nWorkflow, b: N8nWorkflow) => a.name.localeCompare(b.name));
    return { configured: true, ok: true, workflows, checkedAt: new Date().toISOString() };
  } catch (e) {
    return { configured: true, ok: false, error: e instanceof Error ? e.message : "Couldn't read n8n" };
  }
}
