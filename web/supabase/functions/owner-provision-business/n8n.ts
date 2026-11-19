// n8n's own view of the Zella Voice workflows (AUTO-N8N-STATUS): whether each is active in n8n, and its last
// execution. Read with n8n's public API and a key kept as a server secret (N8N_API_KEY, with the instance address in
// N8N_API_URL). The key and the address are never returned. Read only: nothing is activated or run.
// Until the owner creates the key and sets both secrets, the answer is { configured: false } ("Not connected yet").

export type FetchLike = (url: string, init: RequestInit) => Promise<Response>;
export type N8nWorkflow = { id: string; name: string; active: boolean; lastExecution: { status: string; startedAt: string | null; stoppedAt: string | null } | null };
export type N8nStatus =
  | { configured: false }
  | { configured: true; ok: false; error: string }
  | { configured: true; ok: true; workflows: N8nWorkflow[]; checkedAt: string; complete: boolean };

export const N8N_TIMEOUT_MS = 5000;
const PAGE = 250;
// at most this many pages of workflows (2,500); past it the answer says it is incomplete
export const MAX_PAGES = 10;

// "Zella Voice - Follow-up Texts" -> "Follow up Texts": plain words, no dashes on screen
export const workflowLabel = (name: string) => name.replace(/^Zella(\s+Voice)?\s*[-:]\s*/i, "").replace(/[-‐–—]+/g, " ").replace(/\s+/g, " ").trim();
const isZella = (name: unknown) => typeof name === "string" && /^zella/i.test(name.trim());

export async function n8nStatus(env: (name: string) => string | undefined, fetchImpl: FetchLike = fetch): Promise<N8nStatus> {
  const key = env("N8N_API_KEY")?.trim();
  const base = env("N8N_API_URL")?.trim().replace(/\/+$/, "");
  if (!key || !base) return { configured: false };
  if (!/^https:\/\//i.test(base)) return { configured: true, ok: false, error: "The n8n address must start with https://" };
  // The key goes to the configured https address only: a redirect is refused (fetch would otherwise send the header
  // on to wherever it points, even plain http).
  const get = async (path: string) => {
    let res: Response;
    try {
      res = await fetchImpl(`${base}/api/v1/${path}`, { headers: { "X-N8N-API-KEY": key, accept: "application/json" }, redirect: "error", signal: AbortSignal.timeout(N8N_TIMEOUT_MS) });
    } catch {
      throw new Error("Couldn't reach n8n");
    }
    if (res.status === 401 || res.status === 403) throw new Error("n8n refused the key");
    if (!res.ok) throw new Error(`n8n answered ${res.status}`);
    let body: unknown;
    try { body = await res.json(); } catch { throw new Error("n8n sent an answer that isn't readable"); }
    // a list answer must carry its data array; an empty array is a real "none", a missing one is not
    const data = (body as { data?: unknown })?.data;
    if (!Array.isArray(data)) throw new Error("n8n sent an answer that isn't readable");
    const next = (body as { nextCursor?: unknown }).nextCursor;
    return { data: data as Record<string, unknown>[], nextCursor: typeof next === "string" && next ? next : null };
  };
  try {
    // every page of workflows, following n8n's cursor
    const all: Record<string, unknown>[] = [];
    let cursor: string | null = null; let pages = 0; let complete = true;
    do {
      const page = await get(`workflows?limit=${PAGE}${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ""}`);
      all.push(...page.data);
      cursor = page.nextCursor; pages++;
      if (cursor && pages >= MAX_PAGES) { complete = false; break; }
    } while (cursor);
    const zella = all.filter((w) => isZella(w?.name));
    // each Zella Voice workflow's own latest execution, so a busy other workflow can't hide it
    const lastOf = async (id: string): Promise<N8nWorkflow["lastExecution"]> => {
      const { data } = await get(`executions?workflowId=${encodeURIComponent(id)}&limit=1`);
      const e = data[0];
      if (!e) return null;
      const status = typeof e.status === "string" ? e.status : e.finished === true ? "success" : e.stoppedAt ? "error" : "running";
      return { status, startedAt: (e.startedAt as string) ?? null, stoppedAt: (e.stoppedAt as string) ?? null };
    };
    const workflows: N8nWorkflow[] = await Promise.all(zella.map(async (w) => ({
      id: String(w.id), name: workflowLabel(String(w.name)), active: w.active === true, lastExecution: await lastOf(String(w.id)),
    })));
    workflows.sort((a, b) => a.name.localeCompare(b.name));
    return { configured: true, ok: true, workflows, checkedAt: new Date().toISOString(), complete };
  } catch (e) {
    return { configured: true, ok: false, error: e instanceof Error ? e.message : "Couldn't read n8n" };
  }
}
