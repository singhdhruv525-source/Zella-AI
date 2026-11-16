import { assert, assertEquals } from "jsr:@std/assert@1";
import type { SupabaseClient } from "@supabase/supabase-js";
import { type FetchLike, n8nStatus, workflowLabel } from "./n8n.ts";
import { OPS_PERMISSIONS, opsHandlers } from "./ops.ts";

const KEY = "n8n_api_key_must_never_leave_the_server";
const BASE = "https://n8n.example.test";
const env = (vars: Record<string, string>) => (n: string) => vars[n];
const full = env({ N8N_API_KEY: KEY, N8N_API_URL: `${BASE}/` });

// a stub of n8n's public API: records each call, answers workflows and executions
function stubN8n(status = 200, calls: { url: string; key: string | null }[] = []): FetchLike {
  return async (url, init) => {
    calls.push({ url, key: new Headers(init.headers).get("X-N8N-API-KEY") });
    if (status !== 200) return new Response("{}", { status });
    if (url.includes("/api/v1/workflows")) {
      return Response.json({ data: [
        { id: "1", name: "Zella Voice - Follow-up Texts", active: true },
        { id: "2", name: "Zella Voice - Event Router", active: false },
        { id: "3", name: "Someone else's workflow", active: true },
      ] });
    }
    return Response.json({ data: [
      { id: "e3", workflowId: "1", status: "success", startedAt: "2026-11-16T10:00:00Z", stoppedAt: "2026-11-16T10:00:02Z" },
      { id: "e2", workflowId: "1", status: "error", startedAt: "2026-11-16T09:00:00Z", stoppedAt: "2026-11-16T09:00:01Z" },
      { id: "e1", workflowId: "3", status: "success", startedAt: "2026-11-16T08:00:00Z", stoppedAt: null },
    ] });
  };
}

Deno.test("without the key or the address it says not connected yet, and calls nothing", async () => {
  const calls: { url: string; key: string | null }[] = [];
  const cases: Record<string, string>[] = [{}, { N8N_API_KEY: KEY }, { N8N_API_URL: BASE }, { N8N_API_KEY: "  ", N8N_API_URL: BASE }];
  for (const vars of cases) {
    assertEquals(await n8nStatus(env(vars), stubN8n(200, calls)), { configured: false });
  }
  assertEquals(calls.length, 0);
});

Deno.test("active flags and the last execution per Zella Voice workflow; the key is sent to n8n only and never returned", async () => {
  const calls: { url: string; key: string | null }[] = [];
  const out = await n8nStatus(full, stubN8n(200, calls));
  assert(out.configured && out.ok);
  assertEquals(out.workflows.map((w) => [w.name, w.active, w.lastExecution?.status ?? null]), [["Event Router", false, null], ["Follow up Texts", true, "success"]]);
  assertEquals(calls.map((c) => c.url).sort(), [`${BASE}/api/v1/executions?limit=250`, `${BASE}/api/v1/workflows?limit=250`]);
  assert(calls.every((c) => c.key === KEY));
  const text = JSON.stringify(out);
  assert(!text.includes(KEY), "key leaked");
  assert(!text.includes("n8n.example.test"), "address leaked");
  assert(!text.includes("Someone else"), "only Zella Voice workflows");
});

Deno.test("a refused key, an n8n error, an unreachable n8n and a plain http address are each said plainly", async () => {
  const r401 = await n8nStatus(full, stubN8n(401));
  assertEquals(r401, { configured: true, ok: false, error: "n8n refused the key" });
  assertEquals(await n8nStatus(full, stubN8n(500)), { configured: true, ok: false, error: "n8n answered 500" });
  assertEquals(await n8nStatus(full, async () => { throw new TypeError("dns"); }), { configured: true, ok: false, error: "Couldn't reach n8n" });
  const calls: { url: string; key: string | null }[] = [];
  assertEquals(await n8nStatus(env({ N8N_API_KEY: KEY, N8N_API_URL: "http://n8n.example.test" }), stubN8n(200, calls)),
    { configured: true, ok: false, error: "The n8n address must start with https://" });
  assertEquals(calls.length, 0, "the key is never sent over plain http");
});

Deno.test("workflow names read in plain words, without dashes", () => {
  assertEquals(workflowLabel("Zella Voice - Follow-up Emails"), "Follow up Emails");
  assertEquals(workflowLabel("Zella Voice - SMS Sender"), "SMS Sender");
  assertEquals(workflowLabel("Zella: Knowledge"), "Knowledge");
});

Deno.test("n8n_status is an ops action with businesses.view, wired to the stub", async () => {
  assertEquals(OPS_PERMISSIONS.n8n_status, "businesses.view");
  const out = await opsHandlers({} as SupabaseClient, {}, env({}), stubN8n()).handlers.n8n_status();
  assertEquals(out, { configured: false });
});
