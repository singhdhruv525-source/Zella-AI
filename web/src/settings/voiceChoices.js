// The receptionist's voice choices (pure helpers, voiceChoices.test.mjs), shared by Settings (VoicePanel) and the admin create business wizard.
// zella_business_voice_get returns the approved list (sql/zella_business_voice.sql, sql/zella_cartesia_voices.sql):
// each choice has id, name and provider ("11labs", "vapi" or "cartesia"), and Cartesia ones a language and gender.

const PROVIDERS = [["cartesia", "Cartesia"], ["11labs", "ElevenLabs"], ["vapi", "Vapi"]];
const PROVIDER_NAME = Object.fromEntries(PROVIDERS);
const LANGUAGE_NAME = { en: "English", es: "Spanish" };

const CODES = {
  NOT_ALLOWED: "You can't change the voice here. In the business app, owners, admins and managers can; Zella Voice admins need permission to set up AI.",
  UNKNOWN_VOICE: "Pick a voice from the list.",
  NOT_FOUND: "This business no longer exists.",
  // sql/zella_admin_languages.sql: only voices that speak the business's languages are accepted
  VOICE_LANGUAGE: "That voice doesn't match this business's languages. Choose another voice.",
};

export function voiceError(error) {
  const message = error?.message?.trim() ?? String(error);
  if (/does not exist|schema cache|Could not find the/i.test(message)) return "Voice choice needs the latest Zella Voice update. Please ask the Zella Voice team.";
  return CODES[message] ?? message;
}

export const providerOf = (choice) => choice?.provider ?? "11labs";
export const providerName = (provider) => PROVIDER_NAME[provider] ?? provider;
const languageOf = (choice) => choice?.language ?? "en";

// "Katie, Cartesia, English, female": what the voice is and where it comes from
export function voiceLabel(choice) {
  if (!choice) return "";
  const parts = [choice.name ?? choice.id, providerName(providerOf(choice))];
  if (choice.language) parts.push(LANGUAGE_NAME[choice.language] ?? choice.language);
  if (choice.gender) parts.push(choice.gender);
  return parts.join(", ");
}

// Whether a choice is used on calls: Cartesia voices always; ElevenLabs and Vapi voices only while that provider is
// Zella Voice's voice provider.
export const voiceUsable = (choice, platformProvider) => !choice || providerOf(choice) === "cartesia" || providerOf(choice) === platformProvider;

// The wizard's languages ("en-US", "es-US", "en-US+es-US") as base codes
export const languagesOf = (language) => String(language ?? "").split("+").map((l) => l.split("-")[0].toLowerCase()).filter(Boolean);

// Grouped by provider (Cartesia, ElevenLabs, Vapi), voices in the given languages first within each group
export function groupChoices(choices, languages = []) {
  const wanted = new Set(languages);
  return PROVIDERS.map(([provider, name]) => {
    const list = (choices ?? []).filter((c) => providerOf(c) === provider);
    const first = list.filter((c) => wanted.has(languageOf(c)));
    return { provider, name, choices: [...first, ...list.filter((c) => !wanted.has(languageOf(c)))] };
  }).filter((g) => g.choices.length > 0);
}

// The note shown under a chosen voice that calls won't use while another provider is Zella Voice's
export function unusedVoiceNote(choice, platformProvider) {
  if (voiceUsable(choice, platformProvider)) return null;
  return `${providerName(providerOf(choice))} voices are used only while ${providerName(providerOf(choice))} is Zella Voice's voice provider. Calls use the Zella Voice default until then.`;
}

// The default voice's name: from the list, else an ElevenLabs or Vapi voice name as it is; never a raw id with dashes
export function defaultVoiceName(data) {
  const id = data?.default_voice_id;
  if (!id) return null;
  const c = (data.choices ?? []).find((x) => x.id === id);
  if (c) return c.name ?? id;
  return /^[A-Za-z0-9_ ]+$/.test(id) ? id : "set by Zella Voice";
}

// One line for a summary (the wizard's Review step): the chosen voice, or Zella Voice's default
export function voiceSummary(voiceId, data) {
  const find = (id) => (data?.choices ?? []).find((c) => c.id === id);
  if (!voiceId) {
    const d = defaultVoiceName(data);
    return d ? `Zella Voice default (${d})` : "Zella Voice default";
  }
  const c = find(voiceId);
  return c ? voiceLabel(c) : "a voice no longer on the approved list";
}

// ---- The voice carousel (VoiceSelect): which providers to offer as filters, the order of the cards, the dots ----

// Providers that have voices, in the picker's order: the filter chips after "All"
export function providersPresent(choices) {
  const have = new Set((choices ?? []).map(providerOf));
  return PROVIDERS.filter(([p]) => have.has(p)).map(([provider, name]) => ({ provider, name }));
}

// The cards, in order: Zella Voice's default first (id ""), then each provider's voices (Cartesia, ElevenLabs, Vapi),
// voices in the business's languages first within each, as groupChoices orders them. provider "" or "all" keeps all.
export function carouselItems(choices, languages = [], provider = "") {
  const kept = !provider || provider === "all" ? (choices ?? []) : (choices ?? []).filter((c) => providerOf(c) === provider);
  return [{ id: "", isDefault: true }, ...groupChoices(kept, languages).flatMap((g) => g.choices)];
}

// "English" / "Spanish" for a code, "" when unknown; and the card's small line, "English · Female"
export const languageName = (code) => (code ? LANGUAGE_NAME[code] ?? code : "");
export function voiceTraits(choice) {
  if (!choice) return "";
  const g = choice.gender ? choice.gender.charAt(0).toUpperCase() + choice.gender.slice(1) : "";
  return [languageName(choice.language), g].filter(Boolean).join(" · ");
}

// What a screen reader hears when the centred card changes
export function selectedAnnouncement(choice, defaultName) {
  if (!choice) return `${defaultName ? `Zella Voice default, ${defaultName}` : "Zella Voice default"}, selected`;
  return `${voiceLabel(choice)}, selected`;
}

// Samples exist for Cartesia voices and ElevenLabs voices with ElevenLabs' own 20 character id (the voice-sample
// function, hasNativeId); Vapi voices and Vapi's preset ElevenLabs names (burt, marissa, ...) have none
export function canSample(choice) {
  if (!choice?.id) return false;
  if (providerOf(choice) === "cartesia") return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(choice.id);
  return providerOf(choice) === "11labs" && /^[A-Za-z0-9]{20}$/.test(choice.id);
}

// The dots under the carousel: one per card up to `max`; beyond that a window of `max` dots that follows the centred
// card, and a "4 of 21" counter beside it.
export function dotsModel(count, index, max = 9) {
  const n = Math.max(0, count | 0);
  const at = Math.min(Math.max(0, index | 0), Math.max(0, n - 1));
  if (n <= max) return { dots: Array.from({ length: n }, (_, i) => i), counter: null };
  const start = Math.min(Math.max(0, at - Math.floor(max / 2)), n - max);
  return { dots: Array.from({ length: max }, (_, i) => start + i), counter: `${at + 1} of ${n}` };
}

// The card nearest the middle of the track: offsets are each card's centre, centre is the track's middle
export function nearestIndex(offsets, centre) {
  let best = -1, gap = Infinity;
  (offsets ?? []).forEach((o, i) => { const d = Math.abs(o - centre); if (d < gap) { gap = d; best = i; } });
  return best;
}

// How far a card is from the middle (0 centred, 1 one card away or more) as its scale, opacity and glow
export function cardLook(distance) {
  const d = Math.min(1, Math.abs(Number(distance) || 0));
  return { scale: +(1 - 0.16 * d).toFixed(4), opacity: +(1 - 0.5 * d).toFixed(4), glow: +(1 - d).toFixed(4) };
}
