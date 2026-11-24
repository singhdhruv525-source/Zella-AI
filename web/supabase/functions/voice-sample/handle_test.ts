// The voice-sample function with the database, storage and both providers mocked: no real provider or storage call.
//   cd web/supabase/functions/voice-sample && deno test --no-lock --allow-env
import { assert, assertEquals, assertMatch } from "jsr:@std/assert@1";
import { handle } from "./index.ts";
import { SAMPLE_LINES } from "./logic.ts";

Deno.env.set("SUPABASE_URL", "http://db.test");
Deno.env.set("ZELLA_SERVER_SECRET_KEY", "server-key");
Deno.env.set("SUPABASE_ANON_KEY", "anon-key");
const realFetch = globalThis.fetch;
const KATIE = "f786b574-daa5-4673-aa0c-cbe3e8534c02", DANIELA = "5c5ad5e7-1020-476b-8b91-fdcbe9cc313c";
const CHOICES = [
  { id: KATIE, name: "Katie", provider: "cartesia", language: "en", gender: "female" },
  { id: DANIELA, name: "Daniela", provider: "cartesia", language: "es", gender: "female" },
  { id: "burt", name: "Burt", provider: "11labs" },
  { id: "cgSgspJ2msm6clMCkdW9", name: "Jessica", provider: "11labs" },
  { id: "Elliot", name: "Elliot", provider: "vapi" },
];
const MP3 = new Uint8Array([0x49, 0x44, 0x33, 4, 0, 0, 0, 0, 0, 0]);
type Call = { url: string; method: string; headers: Record<string, string>; body: string };
type World = { signDown?: boolean; admin?: string | null; spaces?: unknown[]; stored?: Set<string>; limit?: boolean | null; settings?: Record<string, unknown>;
  provider?: (c: Call) => Response; userStatus?: number };
const j = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status });

function mock(w: World, fn: (calls: Call[]) => Promise<void>) {
  return async () => {
    const calls: Call[] = [];
    const stored = w.stored ?? new Set<string>();
    globalThis.fetch = (async (input: string | URL, init: RequestInit = {}) => {
      const url = String(input);
      const c = { url, method: init.method ?? "GET", headers: (init.headers ?? {}) as Record<string, string>, body: typeof init.body === "string" ? init.body : "" };
      calls.push(c);
      if (url === "http://db.test/auth/v1/user") return w.userStatus ? j({}, w.userStatus) : j({ id: "u1" });
      if (url.endsWith("/rpc/zella_admin_role")) return j(w.admin ?? null);
      if (url.endsWith("/rpc/zella_my_workspaces")) return j(w.spaces ?? []);
      if (url.endsWith("/rpc/zella_rate_limit")) return j(w.limit === undefined ? true : w.limit);
      if (url.endsWith("/rpc/zella_voice_choices")) return j(CHOICES);
      if (url.endsWith("/rpc/zella_setting")) { const k = JSON.parse(c.body).p_key; return j(({ voice_samples_live: true, ...(w.settings ?? { voice_cartesia_model: "cm" }) } as Record<string, unknown>)[k] ?? null); }
      const sign = url.match(/^http:\/\/db\.test\/storage\/v1\/object\/sign\/voice-samples\/(.+)$/);
      if (sign && w.signDown) return j({ error: "unavailable" }, 503);
      if (sign) return stored.has(sign[1]) ? j({ signedURL: `/object/sign/voice-samples/${sign[1]}?token=t` }) : j({ error: "not_found" }, 400);
      const put = url.match(/^http:\/\/db\.test\/storage\/v1\/object\/voice-samples\/(.+)$/);
      if (put && c.method === "POST") { stored.add(put[1]); return j({ Key: put[1] }); }
      if (url.startsWith("https://api.cartesia.ai/") || url.startsWith("https://api.elevenlabs.io/")) {
        c.body = typeof init.body === "string" ? init.body : "";
        return w.provider ? w.provider(c) : new Response(MP3);
      }
      return j({ unexpected: url }, 599);
    }) as typeof fetch;
    try { await fn(calls); } finally { globalThis.fetch = realFetch; Deno.env.delete("CARTESIA_API_KEY"); Deno.env.delete("ELEVENLABS_API_KEY"); }
  };
}
const call = (body: unknown, auth: string | null = "Bearer user-jwt") => handle(new Request("http://fn/voice-sample", { method: "POST", body: JSON.stringify(body),
  headers: { "content-type": "application/json", ...(auth ? { authorization: auth } : {}) } }));
const toProvider = (calls: Call[]) => calls.filter((c) => c.url.startsWith("https://"));
const MEMBER: World = { spaces: [{ id: "b1" }] };

Deno.test("a member, first press: made once with Cartesia, stored privately, a signed link back", mock({ ...MEMBER }, async (calls) => {
  Deno.env.set("CARTESIA_API_KEY", "ck");
  const r = await call({ voice_id: KATIE });
  assertEquals(r.status, 200);
  const out = await r.json();
  assertEquals(out.ok, true); assertEquals(out.expires_in, 300);
  assertMatch(out.url, new RegExp(`^http://db\\.test/storage/v1/object/sign/voice-samples/cartesia/${KATIE}-[0-9a-f]{8}\\.mp3\\?token=t$`));
  const sent = toProvider(calls);
  assertEquals(sent.length, 1);
  assertEquals(JSON.parse(sent[0].body).transcript, SAMPLE_LINES.en);
  assertEquals(JSON.parse(sent[0].body).model_id, "cm");
  const put = calls.find((c) => c.method === "POST" && /\/object\/voice-samples\//.test(c.url))!;
  assertEquals([put.headers["Content-Type"], put.headers.Authorization, put.headers["x-upsert"]], ["audio/mpeg", "Bearer server-key", "false"]);
  // the key goes only to the provider and never back
  assert(!JSON.stringify(out).includes("ck"));
  assertEquals(calls.filter((c) => JSON.stringify(c.headers).includes("ck") && !c.url.startsWith("https://api.cartesia.ai/")).length, 0);
}));

Deno.test("cached: only a signed link, no provider call", mock({ ...MEMBER, stored: new Set() }, async (calls) => {
  Deno.env.set("CARTESIA_API_KEY", "ck");
  await call({ voice_id: DANIELA });
  const before = toProvider(calls).length;
  const r = await call({ voice_id: DANIELA });
  assertEquals((await r.json()).ok, true);
  assertEquals(toProvider(calls).length, before);
  assertEquals(JSON.parse(toProvider(calls)[0].body).transcript, SAMPLE_LINES.es);   // a Spanish voice says the Spanish line
}));

Deno.test("an active Zella Voice admin with no business may listen; ElevenLabs uses its own endpoint and header", mock({ admin: "support_admin", settings: { voice_tts_provider: "vapi" } }, async (calls) => {
  Deno.env.set("ELEVENLABS_API_KEY", "ek");
  const r = await call({ voice_id: "cgSgspJ2msm6clMCkdW9" });
  assertEquals((await r.json()).ok, true);
  const sent = toProvider(calls)[0];
  assertEquals(sent.url, "https://api.elevenlabs.io/v1/text-to-speech/cgSgspJ2msm6clMCkdW9?output_format=mp3_44100_128");
  assertEquals(sent.headers["xi-api-key"], "ek");
  assertEquals(JSON.parse(sent.body), { text: SAMPLE_LINES.en });   // no model unless ElevenLabs is the platform provider
  assertEquals(calls.some((c) => c.url.endsWith("zella_my_workspaces")), false);
}));

Deno.test("not signed in, the server key as a user, an expired sign in: refused before anything else", mock({ ...MEMBER }, async (calls) => {
  assertEquals((await call({ voice_id: KATIE }, null)).status, 401);
  assertEquals((await call({ voice_id: KATIE }, "Bearer server-key")).status, 401);
  assertEquals(calls.length, 0);
}));
Deno.test("an expired sign in: 401", mock({ ...MEMBER, userStatus: 401 }, async () => {
  assertEquals((await call({ voice_id: KATIE })).status, 401);
}));

Deno.test("signed in but neither a member nor an admin: 403, no provider or storage call", mock({ spaces: [] }, async (calls) => {
  Deno.env.set("CARTESIA_API_KEY", "ck");
  assertEquals((await call({ voice_id: KATIE })).status, 403);
  assertEquals(calls.some((c) => c.url.includes("/storage/") || c.url.startsWith("https://")), false);
}));

Deno.test("a voice not on the approved list is refused; a bad id never reaches anything", mock({ ...MEMBER }, async (calls) => {
  Deno.env.set("CARTESIA_API_KEY", "ck");
  const r = await call({ voice_id: "someone-else" });
  assertEquals([r.status, (await r.json()).error], [400, "unknown_voice"]);
  const n = calls.length;
  assertEquals((await call({ voice_id: "../x" })).status, 400);
  assertEquals((await call({})).status, 400);
  assertEquals(calls.length, n);
  assertEquals(toProvider(calls).length, 0);
}));

Deno.test("a Vapi voice: not available, quietly", mock({ ...MEMBER }, async (calls) => {
  const r = await call({ voice_id: "Elliot" });
  assertEquals([r.status, await r.json()], [200, { ok: false, state: "not_available" }]);
  assertEquals(calls.some((c) => c.url.includes("/storage/")), false);
}));

Deno.test("a Vapi preset ElevenLabs name (burt): not available, ElevenLabs never asked", mock({ ...MEMBER }, async (calls) => {
  Deno.env.set("ELEVENLABS_API_KEY", "ek");
  assertEquals(await (await call({ voice_id: "burt" })).json(), { ok: false, state: "not_available" });
  assertEquals(toProvider(calls).length, 0);
}));

Deno.test("storage can't sign right now: try again, and no new paid request for a sample that may exist", mock({ ...MEMBER, signDown: true }, async (calls) => {
  Deno.env.set("CARTESIA_API_KEY", "ck");
  assertEquals((await call({ voice_id: KATIE })).status, 503);
  assertEquals(toProvider(calls).length, 0);
}));

Deno.test("voice_samples_live off: a stored sample still plays, nothing new is made", mock({ ...MEMBER, settings: { voice_cartesia_model: "cm", voice_samples_live: false }, stored: new Set() }, async (calls) => {
  Deno.env.set("CARTESIA_API_KEY", "ck");
  assertEquals(await (await call({ voice_id: KATIE })).json(), { ok: false, state: "not_available" });
  assertEquals(toProvider(calls).length, 0);
}));
Deno.test("voice_samples_live off but the sample is stored: it plays", async () => {
  const stored = new Set<string>();
  await mock({ ...MEMBER, stored }, async () => { Deno.env.set("CARTESIA_API_KEY", "ck"); await call({ voice_id: KATIE }); })();
  await mock({ ...MEMBER, stored, settings: { voice_cartesia_model: "cm", voice_samples_live: false } }, async (calls) => {
    assertEquals((await (await call({ voice_id: KATIE })).json()).ok, true);
    assertEquals(toProvider(calls).length, 0);
  })();
});
Deno.test("a model id with hyphens from settings is used as it is", mock({ ...MEMBER, settings: { voice_cartesia_model: "model-x-2" } }, async (calls) => {
  Deno.env.set("CARTESIA_API_KEY", "ck");
  assertEquals((await (await call({ voice_id: KATIE })).json()).ok, true);
  assertEquals(JSON.parse(toProvider(calls)[0].body).model_id, "model-x-2");
}));

Deno.test("no provider key yet: not available, nothing stored", mock({ ...MEMBER }, async (calls) => {
  const r = await call({ voice_id: KATIE });
  assertEquals([r.status, await r.json()], [200, { ok: false, state: "not_available" }]);
  assertEquals(toProvider(calls).length, 0);
}));

Deno.test("no Cartesia model in settings: not available", mock({ ...MEMBER, settings: {} }, async (calls) => {
  Deno.env.set("CARTESIA_API_KEY", "ck");
  assertEquals((await (await call({ voice_id: KATIE })).json()).state, "not_available");
  assertEquals(toProvider(calls).length, 0);
}));

Deno.test("the provider refuses the key: not available; fails or sends something not audio: try again, nothing stored", async () => {
  Deno.env.set("CARTESIA_API_KEY", "ck");
  await mock({ ...MEMBER, provider: () => j({ error: "bad key" }, 401) }, async () => {
    Deno.env.set("CARTESIA_API_KEY", "ck");
    assertEquals((await (await call({ voice_id: KATIE })).json()).state, "not_available");
  })();
  for (const provider of [() => j({}, 500), () => j({ error: "x" })]) {
    await mock({ ...MEMBER, provider }, async (calls) => {
      Deno.env.set("CARTESIA_API_KEY", "ck");
      assertEquals((await call({ voice_id: KATIE })).status, 503);
      assertEquals(calls.some((c) => c.method === "POST" && /\/object\/voice-samples\//.test(c.url)), false);
    })();
  }
});

Deno.test("over the rate limit: 429; the counter down: 503; both before the list or the provider", async () => {
  for (const [limit, status] of [[false, 429], [null, 503]] as const) {
    await mock({ ...MEMBER, limit }, async (calls) => {
      Deno.env.set("CARTESIA_API_KEY", "ck");
      assertEquals((await call({ voice_id: KATIE })).status, status);
      assertEquals(calls.some((c) => c.url.endsWith("zella_voice_choices") || c.url.startsWith("https://")), false);
    })();
  }
});

Deno.test("limits are per person and per person and voice", mock({ ...MEMBER, stored: new Set() }, async (calls) => {
  Deno.env.set("CARTESIA_API_KEY", "ck");
  await call({ voice_id: KATIE });
  const keys = calls.filter((c) => c.url.endsWith("zella_rate_limit")).map((c) => JSON.parse(c.body).p_key);
  assertEquals(keys, ["voice-sample:user:u1", `voice-sample:voice:u1:${KATIE}`]);
}));

Deno.test("method and body checks", mock({ ...MEMBER }, async () => {
  assertEquals((await handle(new Request("http://fn/voice-sample", { method: "GET" }))).status, 405);
  assertEquals((await handle(new Request("http://fn/voice-sample", { method: "POST", body: "{", headers: { authorization: "Bearer u" } }))).status, 400);
  assertEquals((await handle(new Request("http://fn/voice-sample", { method: "POST", body: "x".repeat(5000), headers: { authorization: "Bearer u" } }))).status, 413);
}));
