// The identity webhook end to end with the database mocked and fake secrets only: off by default, signature checked
// before anything is parsed or stored, each event handed over once with what the provider sent.
import { assertEquals } from "jsr:@std/assert@1";
import { handle } from "./index.ts";
import { sign } from "./test_sign.ts";

const FAKE_SECRET = "fake_test_secret_not_real";
const realFetch = globalThis.fetch;
const env = (on: boolean) => {
  Deno.env.set("SUPABASE_URL", "http://db.test");
  Deno.env.set("ZELLA_SERVER_SECRET_KEY", "server-key");
  if (on) { Deno.env.set("IDENTITY_WEBHOOK_ENABLED", "true"); Deno.env.set("IDENTITY_WEBHOOK_SECRET", FAKE_SECRET); }
  else { Deno.env.delete("IDENTITY_WEBHOOK_ENABLED"); Deno.env.delete("IDENTITY_WEBHOOK_SECRET"); }
};
const event = (id = "evt_1", status = "approved") => JSON.stringify({ data: { type: "event", id, attributes: { name: `inquiry.${status}`,
  "created-at": "2026-11-16T15:00:00Z", payload: { data: { type: "inquiry", id: "inq_1", attributes: { status, "reference-id": "ab".repeat(16) } } } } } });
const post = async (body: string, header?: string, name = "x-identity-signature") => handle(new Request("http://fn/identity-webhook", {
  method: "POST", body, headers: header === undefined ? {} : { [name]: header } }));
const signed = async (body: string, secret = FAKE_SECRET, t = Math.floor(Date.now() / 1000)) => `t=${t},v1=${await sign(body, secret, t)}`;
function db(answer: (body: Record<string, unknown>) => Response) {
  const calls: Record<string, unknown>[] = [];
  globalThis.fetch = (async (_url: string, init: RequestInit = {}) => {
    const b = JSON.parse(String(init.body)); calls.push({ ...b, _auth: (init.headers as Record<string, string>).Authorization });
    return answer(b);
  }) as typeof fetch;
  return calls;
}

Deno.test("off by default: 503 and nothing reaches the database, even with a valid signature", async () => {
  env(false);
  const calls = db(() => new Response('{"result":"applied"}'));
  try {
    const body = event();
    const r = await post(body, await signed(body));
    assertEquals([r.status, await r.text()], [503, "not_enabled"]);
    Deno.env.set("IDENTITY_WEBHOOK_SECRET", FAKE_SECRET);   // a secret alone does not switch it on
    assertEquals((await post(body, await signed(body))).status, 503);
    Deno.env.set("IDENTITY_WEBHOOK_ENABLED", "yes");
    assertEquals((await post(body, await signed(body))).status, 503);
    assertEquals(calls.length, 0);
  } finally { globalThis.fetch = realFetch; }
});

Deno.test("on: bad, missing, stale and wrong secret signatures are refused before parsing", async () => {
  env(true);
  const calls = db(() => new Response('{"result":"applied"}'));
  try {
    const body = event();
    for (const h of [undefined, "", "t=1,v1=00", await signed(body, "fake_wrong_secret"), await signed(body, FAKE_SECRET, Math.floor(Date.now() / 1000) - 600)]) {
      const r = await post(body, h);
      assertEquals([r.status, await r.text()], [401, "bad signature"], String(h));
    }
    const notJson = "{not json";
    assertEquals((await post(notJson, "t=1,v1=00")).status, 401);   // a bad body with a bad signature is never parsed
    assertEquals(calls.length, 0);
  } finally { globalThis.fetch = realFetch; env(false); }
});

Deno.test("on: a signed event is handed to the database once per event id, with the server key", async () => {
  env(true);
  const seen = new Set<string>();
  const calls = db((b) => {
    const id = String(b.p_event_id);
    const result = seen.has(id) ? "duplicate" : "applied"; seen.add(id);
    return new Response(JSON.stringify({ result }));
  });
  try {
    const body = event("evt_7", "declined");
    let r = await post(body, await signed(body));
    assertEquals([r.status, await r.text()], [200, "ok"]);
    r = await post(body, await signed(body), "persona-signature");
    assertEquals([r.status, await r.text()], [200, "duplicate"]);
    assertEquals(calls[0], { p_provider: "persona", p_event_id: "evt_7", p_reference: "ab".repeat(16), p_outcome: "declined",
      p_occurred_at: "2026-11-16T15:00:00.000Z", _auth: "Bearer server-key" });
  } finally { globalThis.fetch = realFetch; env(false); }
});

Deno.test("on: the database's rule still decides (provider none answers off), and failures make the provider retry", async () => {
  env(true);
  try {
    const body = event();
    db(() => new Response('{"result":"off"}'));
    assertEquals((await post(body, await signed(body))).status, 503);
    db(() => new Response("{}", { status: 500 }));
    assertEquals((await post(body, await signed(body))).status, 500);
    globalThis.fetch = (() => Promise.reject(new TypeError("down"))) as typeof fetch;
    assertEquals((await post(body, await signed(body))).status, 500);
    const noId = JSON.stringify({ data: { attributes: {} } });
    db(() => new Response('{"result":"applied"}'));
    assertEquals((await post(noId, await signed(noId))).status, 422);
    const notJson = "{not json";
    assertEquals((await post(notJson, await signed(notJson))).status, 400);
    assertEquals((await handle(new Request("http://fn", { method: "GET" }))).status, 405);
    const big = "x".repeat(256_001);
    assertEquals((await post(big, await signed(big))).status, 413);
  } finally { globalThis.fetch = realFetch; env(false); }
});
