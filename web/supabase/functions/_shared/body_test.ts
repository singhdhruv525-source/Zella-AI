// deno test web/supabase/functions/_shared/body_test.ts
import { assertEquals } from "jsr:@std/assert@1";
import { readBodyLimited } from "./body.ts";

const streamed = (parts: string[]) => new Request("http://x", {
  method: "POST", body: new ReadableStream({ start(c) { for (const p of parts) c.enqueue(new TextEncoder().encode(p)); c.close(); } }),
});

Deno.test("a body within the limit is read whole", async () => {
  assertEquals(await readBodyLimited(new Request("http://x", { method: "POST", body: "hello" }), 10), "hello");
});
Deno.test("a declared length over the limit is refused before reading", async () => {
  const req = new Request("http://x", { method: "POST", body: "x", headers: { "content-length": "999999" } });
  assertEquals(await readBodyLimited(req, 10), null);
});
Deno.test("a streamed body without a length is cut off once it passes the limit", async () => {
  assertEquals(await readBodyLimited(streamed(["12345", "67890", "abc"]), 10), null);
  assertEquals(await readBodyLimited(streamed(["12345", "67890"]), 10), "1234567890");
});
Deno.test("no body reads as empty", async () => {
  assertEquals(await readBodyLimited(new Request("http://x", { method: "POST" }), 10), "");
});
