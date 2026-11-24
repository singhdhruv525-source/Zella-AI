// The voice sample's pure parts: the owner's one line per language, cache names, the provider requests.
//   cd web/supabase/functions/voice-sample && deno test --no-lock
import { assert, assertEquals, assertMatch, assertNotEquals, assertRejects, assertThrows } from "jsr:@std/assert@1";
import { CARTESIA_VERSION, hash8, isSupported, looksLikeMp3, providerRequest, SAMPLE_LINES, sampleLanguage, samplePath, sampleText } from "./logic.ts";

const EN = "Hi, thanks for calling. I'm your Zella Voice receptionist. How can I help you today?";
const ES = "Hola, gracias por llamar. Soy su recepcionista de Zella Voice. ¿En qué puedo ayudarle hoy?";
// the approved list as sql/zella_cartesia_voices.sql makes it, plus ElevenLabs entries without a language
const VOICES = [
  { id: "f786b574-daa5-4673-aa0c-cbe3e8534c02", provider: "cartesia", language: "en" },
  { id: "228fca29-3a0a-435c-8728-5cb483251068", provider: "cartesia", language: "en" },
  { id: "5c5ad5e7-1020-476b-8b91-fdcbe9cc313c", provider: "cartesia", language: "es" },
  { id: "15d0c2e2-8d29-44c3-be23-d585d5f154a1", provider: "cartesia", language: "es" },
  { id: "burt", provider: "11labs" },
  { id: "marissa", provider: "11labs", language: "en" },
];

Deno.test("every voice of a language says exactly the owner's line", () => {
  assertEquals(SAMPLE_LINES, { en: EN, es: ES });
  for (const v of VOICES) assertEquals(sampleText(v.language), v.language === "es" ? ES : EN, v.id);
  assertEquals(sampleText("es-US"), ES);
  assertEquals(sampleText("fr"), EN);   // a language without its own line says the English one
  assertEquals(sampleLanguage(undefined), "en");
});

Deno.test("the line names Zella Voice in full and has no dashes", () => {
  for (const line of Object.values(SAMPLE_LINES)) {
    assertMatch(line, /Zella Voice/);
    assert(!/[-‐-―]/.test(line), line);
  }
});

Deno.test("the cache name is provider, voice and a short hash of the line; a new line makes a new file", async () => {
  const p = await samplePath("cartesia", VOICES[0].id, EN);
  assertMatch(p, /^cartesia\/f786b574-daa5-4673-aa0c-cbe3e8534c02-[0-9a-f]{8}\.mp3$/);
  assertEquals(p, await samplePath("cartesia", VOICES[0].id, EN));
  assertNotEquals(p, await samplePath("cartesia", VOICES[0].id, EN + " "));
  assertNotEquals(await hash8(EN), await hash8(ES));
  await assertRejects(() => samplePath("11labs", "../other", EN));
  await assertRejects(() => samplePath("11labs", "a/b", EN));
});

Deno.test("only Cartesia and ElevenLabs make samples", () => {
  assert(isSupported("cartesia")); assert(isSupported("11labs"));
  assert(!isSupported("vapi")); assert(!isSupported(undefined));
});

Deno.test("Cartesia: the bytes endpoint, the model from settings, the fixed line, an MP3, nothing else", () => {
  const r = providerRequest("cartesia", VOICES[2].id, "es", "test-key", "model-from-setting");
  assertEquals(r.url, "https://api.cartesia.ai/tts/bytes");
  const h = r.init.headers as Record<string, string>;
  assertEquals([h.Authorization, h["cartesia-version"]], ["Bearer test-key", CARTESIA_VERSION]);
  assertEquals(JSON.parse(String(r.init.body)), { model_id: "model-from-setting", transcript: ES, voice: { id: VOICES[2].id },
    output_format: { container: "mp3", sample_rate: 44100, bit_rate: 128000 }, language: "es" });
  assertThrows(() => providerRequest("cartesia", VOICES[2].id, "es", "k", null));
});

Deno.test("ElevenLabs: text to speech for the voice, MP3, the key in its header, model only when set", () => {
  const r = providerRequest("11labs", "burt", "en", "test-key", null);
  assertEquals(r.url, "https://api.elevenlabs.io/v1/text-to-speech/burt?output_format=mp3_44100_128");
  assertEquals((r.init.headers as Record<string, string>)["xi-api-key"], "test-key");
  assertEquals(JSON.parse(String(r.init.body)), { text: EN });
  assertEquals(JSON.parse(String(providerRequest("11labs", "burt", "en", "k", "m1").init.body)), { text: EN, model_id: "m1" });
});

Deno.test("only MP3 bytes of a sane size are kept", () => {
  assert(looksLikeMp3(new Uint8Array([0x49, 0x44, 0x33, 4, 0])));
  assert(looksLikeMp3(new Uint8Array([0xff, 0xfb, 0x90, 0x64])));
  assert(!looksLikeMp3(new TextEncoder().encode('{"error":"x"}')));
  assert(!looksLikeMp3(new Uint8Array(0)));
  assert(!looksLikeMp3(new Uint8Array(1_000_001).fill(0xff)));
});
