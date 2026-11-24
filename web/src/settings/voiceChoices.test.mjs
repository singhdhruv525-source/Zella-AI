// The voice picker's helpers (Settings > Voice and the admin create business wizard): grouped by provider, the
// chosen language first, clear labels, and no dashes in the words people read.
//   cd web && node --test src/settings/voiceChoices.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { groupChoices, languagesOf, unusedVoiceNote, voiceError, voiceLabel, voiceSummary, voiceUsable } from "./voiceChoices.js";

const CHOICES = [
  { id: "burt", name: "Burt", provider: "11labs" },
  { id: "marissa", name: "Marissa", provider: "11labs" },
  { id: "f786b574-daa5-4673-aa0c-cbe3e8534c02", name: "Katie", provider: "cartesia", language: "en", gender: "female" },
  { id: "5c5ad5e7-1020-476b-8b91-fdcbe9cc313c", name: "Daniela", provider: "cartesia", language: "es", gender: "female" },
  { id: "15d0c2e2-8d29-44c3-be23-d585d5f154a1", name: "Pedro", provider: "cartesia", language: "es", gender: "male" },
  { id: "Elliot", name: "Elliot", provider: "vapi" },
];

test("grouped by provider: Cartesia, ElevenLabs, Vapi; empty groups left out", () => {
  assert.deepEqual(groupChoices(CHOICES).map((g) => g.name), ["Cartesia", "ElevenLabs", "Vapi"]);
  assert.deepEqual(groupChoices(CHOICES.filter((c) => c.provider === "11labs")).map((g) => g.name), ["ElevenLabs"]);
  assert.deepEqual(groupChoices([]), []);
});

test("an entry without a provider is ElevenLabs (the list before Cartesia)", () => {
  assert.deepEqual(groupChoices([{ id: "burt", name: "Burt" }]).map((g) => g.provider), ["11labs"]);
});

test("voices in the chosen language come first in each group, in list order", () => {
  const es = groupChoices(CHOICES, languagesOf("es-US")).find((g) => g.provider === "cartesia");
  assert.deepEqual(es.choices.map((c) => c.name), ["Daniela", "Pedro", "Katie"]);
  const en = groupChoices(CHOICES, languagesOf("en-US")).find((g) => g.provider === "cartesia");
  assert.deepEqual(en.choices.map((c) => c.name), ["Katie", "Daniela", "Pedro"]);
  assert.deepEqual(languagesOf("en-US+es-US"), ["en", "es"]);
  assert.deepEqual(languagesOf(undefined), []);
});

test("labels say the voice, provider, language and gender", () => {
  assert.equal(voiceLabel(CHOICES[2]), "Katie, Cartesia, English, female");
  assert.equal(voiceLabel(CHOICES[3]), "Daniela, Cartesia, Spanish, female");
  assert.equal(voiceLabel(CHOICES[0]), "Burt, ElevenLabs");
  assert.equal(voiceLabel(CHOICES[5]), "Elliot, Vapi");
});

test("Cartesia voices are always used; ElevenLabs and Vapi only under their own provider", () => {
  assert.equal(voiceUsable(CHOICES[2], "vapi"), true);
  assert.equal(voiceUsable(CHOICES[0], "11labs"), true);
  assert.equal(voiceUsable(CHOICES[0], "cartesia"), false);
  assert.equal(voiceUsable(undefined, "vapi"), true);
  assert.equal(unusedVoiceNote(CHOICES[2], "vapi"), null);
  assert.match(unusedVoiceNote(CHOICES[0], "vapi"), /ElevenLabs voices are used only while ElevenLabs is Zella Voice's voice provider/);
});

test("the review summary names the voice or the default", () => {
  const data = { choices: CHOICES, default_voice_id: "burt" };
  assert.equal(voiceSummary("", data), "Zella Voice default (Burt)");
  assert.equal(voiceSummary("", undefined), "Zella Voice default");
  assert.equal(voiceSummary(CHOICES[3].id, data), "Daniela, Cartesia, Spanish, female");
  assert.equal(voiceSummary("gone", data), "gone");
});

test("errors in words; no dashes anywhere people read", () => {
  assert.equal(voiceError({ message: "UNKNOWN_VOICE" }), "Pick a voice from the list.");
  assert.match(voiceError({ message: "Could not find the function" }), /latest Zella Voice update/);
  const words = [...CHOICES.map(voiceLabel), unusedVoiceNote(CHOICES[0], "vapi"), voiceSummary("", {}), voiceError({ message: "NOT_ALLOWED" })];
  for (const w of words) assert.doesNotMatch(w, /[-‐-―]/, w);
});
