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

// One line for a summary (the wizard's Review step): the chosen voice, or Zella Voice's default
export function voiceSummary(voiceId, data) {
  const find = (id) => (data?.choices ?? []).find((c) => c.id === id);
  if (!voiceId) {
    const d = data?.default_voice_id ? find(data.default_voice_id)?.name ?? data.default_voice_id : null;
    return d ? `Zella Voice default (${d})` : "Zella Voice default";
  }
  const c = find(voiceId);
  return c ? voiceLabel(c) : voiceId;
}
