// Zella Voice - the voice sample's pure parts (logic_test.ts): the one line every sample says, where a sample is
// cached, and the one text to speech request per provider. No business data is ever part of a request: only the
// fixed line, the voice and the model.
//
// Request formats, read from the providers' own SDKs (not called anywhere in tests):
//   Cartesia   @cartesia/cartesia-js 5.2.0, resources/tts: POST https://api.cartesia.ai/tts/bytes, Authorization
//              Bearer <key>, header cartesia-version 2026-08-14, body TTSGenerateParams { model_id, transcript,
//              voice: { id }, output_format: MP3OutputFormat { container "mp3", sample_rate, bit_rate }, language }.
//   ElevenLabs @elevenlabs/elevenlabs-js 2.80.0, textToSpeech.convert: POST https://api.elevenlabs.io/v1/text-to-speech/
//              <voice_id>?output_format=mp3_44100_128, header xi-api-key, body { text, model_id?, language_code? }.
// Neither has been tried against the real service from here; the first press after deploy is the first real call.

// The owner's line (24 Nov 2026), the same for every voice of a language. Changing it changes the cache file names.
export const SAMPLE_LINES = {
  en: "Hi, thanks for calling. I'm your Zella Voice receptionist. How can I help you today?",
  es: "Hola, gracias por llamar. Soy su recepcionista de Zella Voice. ¿En qué puedo ayudarle hoy?",
} as const;
export type SampleLanguage = keyof typeof SAMPLE_LINES;

// A voice's language as the approved list gives it ("es", "en"); anything else (or none) says the English line
export function sampleLanguage(language: unknown): SampleLanguage {
  const base = String(language ?? "").split("-")[0].toLowerCase();
  return base === "es" ? "es" : "en";
}
export const sampleText = (language: unknown) => SAMPLE_LINES[sampleLanguage(language)];

// Voice ids as the approved list holds them: Cartesia UUIDs, ElevenLabs ids, Vapi names. Nothing that could leave the folder.
export const VOICE_ID = /^[A-Za-z0-9_-]{1,64}$/;
export const SUPPORTED = ["cartesia", "11labs"] as const;
export type Provider = typeof SUPPORTED[number];
export const isSupported = (provider: unknown): provider is Provider => SUPPORTED.includes(provider as Provider);

export async function hash8(text: string): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)));
  return [...digest.slice(0, 4)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

// <provider>/<voice_id>-<hash of the line>.mp3 in the private voice-samples bucket
export async function samplePath(provider: Provider, voiceId: string, text: string): Promise<string> {
  if (!VOICE_ID.test(voiceId)) throw new Error("bad voice id");
  return `${provider}/${voiceId}-${await hash8(text)}.mp3`;
}

export const CARTESIA_VERSION = "2026-08-14";
export type ProviderRequest = { url: string; init: RequestInit };

// The one request for a sample. model: Cartesia's from voice_cartesia_model (required); ElevenLabs' only when the
// platform's own voice settings name one, otherwise ElevenLabs' default.
export function providerRequest(provider: Provider, voiceId: string, language: SampleLanguage, key: string, model: string | null): ProviderRequest {
  const transcript = SAMPLE_LINES[language];
  if (provider === "cartesia") {
    if (!model) throw new Error("no model");
    return {
      url: "https://api.cartesia.ai/tts/bytes",
      init: {
        method: "POST",
        headers: { "Content-Type": "application/json", Accept: "audio/mpeg", Authorization: `Bearer ${key}`, "cartesia-version": CARTESIA_VERSION },
        body: JSON.stringify({ model_id: model, transcript, voice: { id: voiceId }, output_format: { container: "mp3", sample_rate: 44100, bit_rate: 128000 }, language }),
      },
    };
  }
  return {
    url: `https://api.elevenlabs.io/v1/text-to-speech/${encodeURIComponent(voiceId)}?output_format=mp3_44100_128`,
    init: {
      method: "POST",
      headers: { "Content-Type": "application/json", Accept: "audio/mpeg", "xi-api-key": key },
      body: JSON.stringify({ text: transcript, ...(model ? { model_id: model } : {}) }),
    },
  };
}

export const MAX_SAMPLE_BYTES = 1_000_000;
// MP3 bytes start with an ID3 tag or a frame sync; anything else (an error page, JSON) is not stored
export function looksLikeMp3(bytes: Uint8Array): boolean {
  if (bytes.length < 4 || bytes.length > MAX_SAMPLE_BYTES) return false;
  if (bytes[0] === 0x49 && bytes[1] === 0x44 && bytes[2] === 0x33) return true;   // "ID3"
  return bytes[0] === 0xff && (bytes[1] & 0xe0) === 0xe0;
}
