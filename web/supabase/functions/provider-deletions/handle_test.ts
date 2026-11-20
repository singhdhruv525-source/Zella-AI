// provider-deletions with the database and Vapi mocked: nothing is sent anywhere.
import { assertEquals } from "jsr:@std/assert@1";
import { handle, runOnce, type Deps } from "./index.ts";
Deno.env.set("SUPABASE_URL", "http://db.test"); Deno.env.set("ZELLA_SERVER_SECRET_KEY", "server-key-for-tests-0123456789");
function fake(rows: unknown, vapi: (id: string) => number | Error) {
  const results: Record<string, unknown>[] = [], deleted: string[] = [];
  const deps: Deps = {
    rpc: async (fn, args) => { if (fn === "zella_provider_deletions_claim") return { ok: true, data: rows }; results.push(args); return { ok: true, data: args.p_outcome }; },
    vapiDelete: async (id) => { deleted.push(id); const r = vapi(id); if (r instanceof Error) throw r; return r; },
  };
  return { deps, results, deleted };
}
const R = (id: string, ext: string) => ({ id, provider: "vapi", kind: "call", external_id: ext });
Deno.test("only the server key may run it", async () => {
  const { deps, deleted } = fake([R("1", "c1")], () => 200);
  assertEquals((await handle(new Request("http://fn", { method: "POST", headers: { authorization: "Bearer nope" } }), deps)).status, 401);
  assertEquals(deleted.length, 0);
});
Deno.test("each claimed call is deleted at Vapi and the result recorded", async () => {
  const { deps, results, deleted } = fake([R("1", "c1"), R("2", "gone"), R("3", "c3")], (id) => (id === "gone" ? 404 : id === "c3" ? 500 : 200));
  assertEquals(await runOnce(deps, true), { done: 1, not_found: 1, failed: 1, unrecorded: 0 });
  assertEquals(deleted, ["c1", "gone", "c3"]);
  assertEquals(results.map((r) => r.p_outcome), ["done", "not_found", "failed"]);
});
Deno.test("nothing claimed (vapi_deletion_live off): nothing is sent", async () => {
  const { deps, deleted } = fake([], () => 200);
  assertEquals(await runOnce(deps, true), { done: 0, not_found: 0, failed: 0, unrecorded: 0 });
  assertEquals(deleted.length, 0);
});
Deno.test("without a Vapi key nothing is claimed, so no attempt is used up", async () => {
  let claimed = 0;
  const deps: Deps = { rpc: async (fn) => { if (fn === "zella_provider_deletions_claim") claimed++; return { ok: true, data: [] }; }, vapiDelete: async () => 200 };
  assertEquals([await runOnce(deps, false), claimed], [{ error: "not_configured" }, 0]);
});
Deno.test("a result the database didn't accept isn't counted as done", async () => {
  const deps: Deps = { rpc: async (fn) => (fn === "zella_provider_deletions_claim" ? { ok: true, data: [R("1", "c1")] } : { ok: true, data: "not_sending" }), vapiDelete: async () => 200 };
  assertEquals(await runOnce(deps, true), { done: 0, not_found: 0, failed: 0, unrecorded: 1 });
});
Deno.test("an odd id or a network error never throws", async () => {
  const { deps, results, deleted } = fake([R("1", "../x"), R("2", "c2")], () => new TypeError("reset"));
  await runOnce(deps, true);
  assertEquals([deleted, results.map((r) => r.p_error)], [["c2"], ["unsupported", "TypeError"]]);
});
