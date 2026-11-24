// Zella Voice - a short sample of an approved receptionist voice, for the voice picker (Settings > Voice and the admin
// create business wizard).
//   POST { voice_id }   a signed in member of a business, or an active Zella Voice admin
// Answers { ok: true, url, expires_in } (a signed link to an MP3 that lives 5 minutes), or { ok: false, state:
// "not_available" } when there is no sample to give yet (a Vapi voice, a provider key or model not set): the picker
// says so quietly on the card. A sample is made once per voice and line (logic.ts) and kept in the private
// voice-samples bucket (sql/zella_voice_samples.sql); later presses only sign a link. The provider keys are the
// function secrets CARTESIA_API_KEY and ELEVENLABS_API_KEY, never logged or returned.
// verify_jwt is off (config.toml), like the other functions that check the caller through the database.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { withCors } from "../_shared/cors.ts";
import { asObject, readJsonLimited } from "../_shared/body.ts";
import { checkLimits, TOO_MANY_ATTEMPTS } from "../_shared/rate_limit.ts";
import { isSupported, looksLikeMp3, providerRequest, sampleLanguage, samplePath, sampleText, VOICE_ID } from "./logic.ts";

// Per person (any voice) and per person and voice: a person trying voices never reaches these; they stop a loop.
export const USER_LIMIT = { max: 40, seconds: 600 }, VOICE_LIMIT = { max: 6, seconds: 60 };
export const LINK_SECONDS = 300;
const TIMEOUT_MS = 10_000, PROVIDER_TIMEOUT_MS = 15_000;   // BE-3
const BUCKET = "voice-samples";
const KEY_ENV = { cartesia: "CARTESIA_API_KEY", "11labs": "ELEVENLABS_API_KEY" } as const;

const json = (body: unknown, status: number) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
const notAvailable = () => json({ ok: false, state: "not_available" }, 200);
const tryAgain = () => json({ ok: false, error: "try_again" }, 503);

export async function handle(req: Request): Promise<Response> {
  try { return await route(req); } catch { return tryAgain(); }   // a timeout or a failed call is "try again", never a 500
}

async function route(req: Request): Promise<Response> {
  if (req.method !== "POST") return json({ ok: false, error: "method_not_allowed" }, 405);
  const base = Deno.env.get("SUPABASE_URL"), server = Deno.env.get("ZELLA_SERVER_SECRET_KEY"), anon = Deno.env.get("SUPABASE_ANON_KEY");
  if (!base || !server || !anon) return json({ ok: false, error: "not_configured" }, 503);
  const read = await readJsonLimited(req, 4_000);   // SEC-12
  if (!read.ok) return json({ ok: false, error: read.error }, read.error === "too_large" ? 413 : 400);
  const body = asObject(read.value);
  const voiceId = typeof body?.voice_id === "string" ? body.voice_id : "";
  if (!VOICE_ID.test(voiceId)) return json({ ok: false, error: "bad_request" }, 400);
  const auth = req.headers.get("authorization") ?? "";
  if (!/^Bearer\s+\S+/i.test(auth) || auth.includes(server)) return json({ ok: false, error: "sign_in_required" }, 401);

  const asUser = { apikey: anon, Authorization: auth }, asServer = { apikey: server, Authorization: `Bearer ${server}` };
  const rpc = (fn: string, args: unknown, headers: Record<string, string>) => fetch(`${base}/rest/v1/rpc/${fn}`, {
    method: "POST", headers: { "Content-Type": "application/json", ...headers }, body: JSON.stringify(args), signal: AbortSignal.timeout(TIMEOUT_MS) });

  // who: the sign in, then an active Zella Voice admin (zella_admin_role) or an active member of a business (zella_my_workspaces)
  const who = await fetch(`${base}/auth/v1/user`, { headers: asUser, signal: AbortSignal.timeout(TIMEOUT_MS) });
  if (!who.ok) return who.status >= 500 ? tryAgain() : json({ ok: false, error: "sign_in_required" }, 401);
  const user = await who.json().catch(() => null);
  if (!user || typeof user.id !== "string" || !user.id) return json({ ok: false, error: "sign_in_required" }, 401);
  const role = await rpc("zella_admin_role", {}, asUser);
  if (!role.ok) return tryAgain();
  if (typeof (await role.json().catch(() => null)) !== "string") {
    const spaces = await rpc("zella_my_workspaces", {}, asUser);
    if (!spaces.ok) return tryAgain();
    const list = await spaces.json().catch(() => null);
    if (!Array.isArray(list) || list.length === 0) return json({ ok: false, error: "not_allowed" }, 403);
  }

  const limited = await checkLimits(base, server, [[`voice-sample:user:${user.id}`, USER_LIMIT.max, USER_LIMIT.seconds],
    [`voice-sample:voice:${user.id}:${voiceId}`, VOICE_LIMIT.max, VOICE_LIMIT.seconds]]);
  if (limited === "limited") return json({ ok: false, error: "rate_limited", message: TOO_MANY_ATTEMPTS }, 429);
  if (limited === "unavailable") return tryAgain();

  // only a voice on the approved list
  const choicesRes = await rpc("zella_voice_choices", {}, asServer);
  if (!choicesRes.ok) return tryAgain();
  const choices = await choicesRes.json().catch(() => null);
  const choice = Array.isArray(choices) ? choices.find((c) => c && typeof c === "object" && c.id === voiceId) : null;
  if (!choice) return json({ ok: false, error: "unknown_voice" }, 400);
  const provider = choice.provider ?? "11labs";
  if (!isSupported(provider)) return notAvailable();
  const language = sampleLanguage(choice.language);
  const path = await samplePath(provider, voiceId, sampleText(language));

  const sign = async () => {
    const r = await fetch(`${base}/storage/v1/object/sign/${BUCKET}/${path}`, { method: "POST", headers: { "Content-Type": "application/json", ...asServer },
      body: JSON.stringify({ expiresIn: LINK_SECONDS }), signal: AbortSignal.timeout(TIMEOUT_MS) });
    if (!r.ok) return null;
    const signed = (await r.json().catch(() => null))?.signedURL;
    return typeof signed === "string" && signed.startsWith("/object/sign/") ? `${base}/storage/v1${signed}` : null;
  };
  const cached = await sign();
  if (cached) return json({ ok: true, url: cached, expires_in: LINK_SECONDS }, 200);

  // not made yet: once, with the provider's key and model; nothing is said about the business
  const key = Deno.env.get(KEY_ENV[provider]);
  if (!key) return notAvailable();
  const setting = async (k: string) => {
    const r = await rpc("zella_setting", { p_key: k, p_default: null }, asServer);
    if (!r.ok) throw new Error("setting");
    const v = await r.json().catch(() => null);
    return typeof v === "string" && /^[A-Za-z0-9_.]{1,64}$/.test(v) ? v : null;
  };
  let model: string | null;
  if (provider === "cartesia") {
    model = await setting("voice_cartesia_model");
    if (!model) return notAvailable();
  } else {
    model = (await setting("voice_tts_provider")) === "11labs" ? await setting("voice_tts_model") : null;
  }
  const ask = providerRequest(provider, voiceId, language, key, model);
  const made = await fetch(ask.url, { ...ask.init, signal: AbortSignal.timeout(PROVIDER_TIMEOUT_MS) }).catch(() => null);
  if (!made?.ok) {
    console.error("voice sample not made", provider, made ? made.status : "no answer");   // the status only, never the key or the body
    return made && (made.status === 401 || made.status === 403) ? notAvailable() : tryAgain();
  }
  const bytes = new Uint8Array(await made.arrayBuffer());
  if (!looksLikeMp3(bytes)) return tryAgain();
  const put = await fetch(`${base}/storage/v1/object/${BUCKET}/${path}`, {
    method: "POST", headers: { "Content-Type": "audio/mpeg", "x-upsert": "false", "cache-control": "31536000", ...asServer },
    body: bytes, signal: AbortSignal.timeout(TIMEOUT_MS) });
  // another press may have stored the same sample a moment earlier: that copy is used
  if (!put.ok && put.status !== 409 && put.status !== 400) return tryAgain();
  const url = await sign();
  return url ? json({ ok: true, url, expires_in: LINK_SECONDS }, 200) : tryAgain();
}

if (import.meta.main) Deno.serve(withCors(handle));
