// The voice picker's helpers (Settings > Voice and the admin create business wizard): grouped by provider, the
// chosen language first, clear labels, and no dashes in the words people read.
//   cd web && node --test src/settings/voiceChoices.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { canSample, cardLook, carouselItems, defaultVoiceName, dotsModel, groupChoices, languagesOf, nearestIndex, providersPresent, selectedAnnouncement, unusedVoiceNote, voiceError, voiceLabel, voiceSummary, voiceTraits, voiceUsable } from "./voiceChoices.js";

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
  assert.equal(voiceSummary("gone", data), "a voice no longer on the approved list");   // never a raw id
});

test("the default voice by name, never a raw id with dashes", () => {
  assert.equal(defaultVoiceName({ choices: CHOICES, default_voice_id: "burt" }), "Burt");
  assert.equal(defaultVoiceName({ choices: CHOICES, default_voice_id: CHOICES[2].id }), "Katie");
  assert.equal(defaultVoiceName({ choices: [], default_voice_id: "Elliot" }), "Elliot");
  assert.equal(defaultVoiceName({ choices: [], default_voice_id: "0b5a1b6c-0000-4000-8000-000000000000" }), "set by Zella Voice");
  assert.equal(defaultVoiceName({}), null);
});

test("errors in words; no dashes anywhere people read", () => {
  assert.equal(voiceError({ message: "UNKNOWN_VOICE" }), "Pick a voice from the list.");
  assert.match(voiceError({ message: "Could not find the function" }), /latest Zella Voice update/);
  const words = [...CHOICES.map(voiceLabel), unusedVoiceNote(CHOICES[0], "vapi"), voiceSummary("", {}), voiceError({ message: "NOT_ALLOWED" })];
  for (const w of words) assert.doesNotMatch(w, /[-‐-―]/, w);
});

test("carousel: the default first, then Cartesia, ElevenLabs, Vapi, the business's languages first in each", () => {
  const ids = (items) => items.map((c) => c.name ?? "default");
  assert.deepEqual(ids(carouselItems(CHOICES, ["es"])), ["default", "Daniela", "Pedro", "Katie", "Burt", "Marissa", "Elliot"]);
  assert.deepEqual(ids(carouselItems(CHOICES, ["en"], "cartesia")), ["default", "Katie", "Daniela", "Pedro"]);
  assert.deepEqual(ids(carouselItems(CHOICES, [], "all")), ["default", "Katie", "Daniela", "Pedro", "Burt", "Marissa", "Elliot"]);
  assert.deepEqual(ids(carouselItems([], [])), ["default"]);
  assert.equal(carouselItems(CHOICES)[0].id, "");
});

test("filter chips: only providers that have voices, in order", () => {
  assert.deepEqual(providersPresent(CHOICES).map((p) => p.name), ["Cartesia", "ElevenLabs", "Vapi"]);
  assert.deepEqual(providersPresent(CHOICES.filter((c) => c.provider !== "cartesia")).map((p) => p.provider), ["11labs", "vapi"]);
  assert.deepEqual(providersPresent([]), []);
});

test("card words: traits, announcement, which voices have samples", () => {
  assert.equal(voiceTraits(CHOICES[2]), "English · Female");
  assert.equal(voiceTraits(CHOICES[0]), "");
  assert.equal(selectedAnnouncement(CHOICES[2]), "Katie, Cartesia, English, female, selected");
  assert.equal(selectedAnnouncement(null, "Burt"), "Zella Voice default, Burt, selected");
  assert.equal(canSample(CHOICES[2]), true); assert.equal(canSample(CHOICES[0]), true);
  assert.equal(canSample(CHOICES[5]), false); assert.equal(canSample(null), false);
  for (const w of [voiceTraits(CHOICES[4]), selectedAnnouncement(CHOICES[3]), selectedAnnouncement(null)]) assert.doesNotMatch(w, /[-‐-―]/, w);
});

test("dots: one per card up to nine, then a window that follows and a counter", () => {
  assert.deepEqual(dotsModel(5, 2), { dots: [0, 1, 2, 3, 4], counter: null });
  assert.deepEqual(dotsModel(21, 3), { dots: [0, 1, 2, 3, 4, 5, 6, 7, 8], counter: "4 of 21" });
  assert.deepEqual(dotsModel(21, 12).dots, [8, 9, 10, 11, 12, 13, 14, 15, 16]);
  assert.deepEqual(dotsModel(21, 20), { dots: [12, 13, 14, 15, 16, 17, 18, 19, 20], counter: "21 of 21" });
  assert.deepEqual(dotsModel(0, 0), { dots: [], counter: null });
});

test("the centred card and how its neighbours look", () => {
  assert.equal(nearestIndex([100, 340, 580], 350), 1);
  assert.equal(nearestIndex([], 10), -1);
  assert.deepEqual(cardLook(0), { scale: 1, opacity: 1, glow: 1 });
  assert.deepEqual(cardLook(1), { scale: 0.84, opacity: 0.5, glow: 0 });
  assert.deepEqual(cardLook(-3), cardLook(1));
  assert.deepEqual(cardLook(0.5), { scale: 0.92, opacity: 0.75, glow: 0.5 });
});
