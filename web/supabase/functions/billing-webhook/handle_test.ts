import { assertEquals } from "jsr:@std/assert@1";
import { handle } from "./index.ts";
Deno.env.set("STRIPE_WEBHOOK_SECRET", "test");
Deno.env.set("ZELLA_SERVER_SECRET_KEY", "test");
Deno.test("body limit uses bytes and cancels oversized streams", async () => {
  let cancelled = false;
  const body = new ReadableStream({ pull(c) { c.enqueue(new TextEncoder().encode("é".repeat(250001))); }, cancel() { cancelled = true; } });
  const r = await handle(new Request("http://fn", { method: "POST", body }));
  assertEquals(r.status, 413);
  assertEquals(cancelled, true);
  assertEquals((await handle(new Request("http://fn", { method: "POST", headers: { "content-length": "500001" }, body: "x" }))).status, 413);
});
Deno.test("within-limit signed body reaches RPC; invalid results stay private", async () => {
  const raw = JSON.stringify({ id: "evt", type: "customer.subscription.deleted", data: { object: { id: "sub" } } });
  const t = Math.floor(Date.now() / 1000), enc = new TextEncoder();
  const key = await crypto.subtle.importKey("raw", enc.encode("test"), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = [...new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode(`${t}.${raw}`)))].map(x => x.toString(16).padStart(2, "0")).join("");
  const real = globalThis.fetch;
  try {
    for (const [body, status] of [['"processed"', 200], ['"private failure"', 500], ['{}', 500], ['{', 500]] as const) {
      globalThis.fetch = (() => Promise.resolve(new Response(body))) as typeof fetch;
      const r = await handle(new Request("http://fn", { method: "POST", headers: { "stripe-signature": `t=${t},v1=${mac}` }, body: raw }));
      assertEquals(r.status, status);
      assertEquals(await r.text(), status === 200 ? "ok" : "error");
    }
  } finally { globalThis.fetch = real; }
});
