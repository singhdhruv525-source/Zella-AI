// The shared rate limit helper with the database counter mocked.
import { assertEquals } from "jsr:@std/assert@1";
import { checkLimits } from "./rate_limit.ts";

const realFetch = globalThis.fetch;
async function run(answer: (key: string) => Response) {
  const sent: { url: string; auth: string; body: Record<string, unknown> }[] = [];
  globalThis.fetch = (async (url: string, init: RequestInit = {}) => {
    const body = JSON.parse(String(init.body));
    sent.push({ url: String(url), auth: (init.headers as Record<string, string>).Authorization, body });
    return answer(String(body.p_key));
  }) as typeof fetch;
  try { return { answer: await checkLimits("http://db.test", "server-key", [["a", 1, 60], ["b", 2, 600]]), sent }; }
  finally { globalThis.fetch = realFetch; }
}
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s });

Deno.test("every limit is counted in order with the server key", async () => {
  const r = await run(() => json(true));
  assertEquals(r.answer, "ok");
  assertEquals(r.sent, [
    { url: "http://db.test/rest/v1/rpc/zella_rate_limit", auth: "Bearer server-key", body: { p_key: "a", p_max: 1, p_window_seconds: 60 } },
    { url: "http://db.test/rest/v1/rpc/zella_rate_limit", auth: "Bearer server-key", body: { p_key: "b", p_max: 2, p_window_seconds: 600 } },
  ]);
});
Deno.test("the first limit over its maximum stops the rest", async () => {
  const r = await run(() => json(false));
  assertEquals([r.answer, r.sent.length], ["limited", 1]);
});
Deno.test("a counter that can't be checked is unavailable, never ok", async () => {
  for (const answer of [() => json({ message: "boom" }, 500), () => json("yes"), () => new Response("{"), () => { throw new TypeError("network"); }]) {
    assertEquals((await run(answer)).answer, "unavailable");
  }
});
Deno.test("idKey: every spelling of one business id shares one counter key", async () => {
  const { idKey } = await import("./rate_limit.ts");
  const id = "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11";
  for (const spelling of [id, id.toUpperCase(), "a0ee-bc99-9c0b-4ef8-bb6d6bb9bd380a11", "a0eebc999c0b4ef8bb6d6bb9bd380a11"]) assertEquals(idKey(spelling), id);
  assertEquals(idKey("Not-A-Uuid"), "not-a-uuid");
});
