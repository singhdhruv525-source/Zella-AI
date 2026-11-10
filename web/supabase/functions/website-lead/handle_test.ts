import { assertEquals } from "jsr:@std/assert@1";
import { handle } from "./index.ts";
Deno.env.set("SUPABASE_URL", "http://db.test");
Deno.env.set("ZELLA_SERVER_SECRET_KEY", "test");
const call = () => handle(new Request("http://fn", { method: "POST", headers: { origin: "https://site.test" }, body: "{}" }));
Deno.test("upstream failures are structured and preserve origin", async () => {
  const real = globalThis.fetch;
  try {
    for (const body of ["{", "null", "[]", '{}', '{"ok":"yes"}']) {
      globalThis.fetch = (() => Promise.resolve(new Response(body))) as typeof fetch;
      const r = await call();
      assertEquals(r.status, 502);
      assertEquals((await r.json()).error, "try_again");
      assertEquals(r.headers.get("access-control-allow-origin"), "https://site.test");
    }
    globalThis.fetch = (() => Promise.reject(new Error("network"))) as typeof fetch;
    assertEquals((await call()).status, 502);
  } finally { globalThis.fetch = real; }
});
Deno.test("RPC output is restricted to approved fields and errors", async () => {
  const real = globalThis.fetch;
  try {
    for (const [error, status] of [["too_many_requests", 429], ["origin_not_allowed", 403], ["unknown_form", 400], ["unknown_kind", 400], ["invalid_phone", 400], ["invalid_email", 400], ["no_contact", 400], ["secret_error", 400]] as const) {
      globalThis.fetch = (() => Promise.resolve(Response.json({ ok: false, error, message: "Try again", secret: "hidden" }))) as typeof fetch;
      const r = await call();
      assertEquals(r.status, status);
      assertEquals(await r.json(), { ok: false, error: error === "secret_error" ? "try_again" : error, message: "Try again" });
    }
  } finally { globalThis.fetch = real; }
});
