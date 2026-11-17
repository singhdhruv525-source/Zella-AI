// Pure parts of the identity webhook (no network), tested in logic_test.ts. Provider neutral: an identity provider is
// a name plus a way to read its events; Persona is the first one described. Nothing here calls a provider.

const enc = new TextEncoder();
const hex = (b: ArrayBuffer) => [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, "0")).join("");

// Signature headers read, in order. "x-identity-signature" is the contract's name; "persona-signature" is the header
// Persona documents. Confirm against the provider's documentation before switching the receiver on.
export const SIGNATURE_HEADERS = ["x-identity-signature", "persona-signature"];
export const MAX_AGE_SECONDS = 300;   // a signature older or newer than 5 minutes is a replay
export const MAX_BODY_BYTES = 256_000;

// Compares two strings in constant time, so the time taken gives nothing away.
export function sameText(a: string, b: string): boolean {
  const x = enc.encode(a), y = enc.encode(b);
  let diff = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

// "t=<unix seconds>,v1=<hex HMAC SHA256 of "<t>.<raw body>">", over the exact bytes received, within 5 minutes.
// Several v1 values (a secret being rotated) are accepted if any one matches.
export async function verifySignature(raw: Uint8Array, header: string | null, secret: string, nowSeconds = Date.now() / 1000): Promise<boolean> {
  if (!header || !secret) return false;
  const parts = header.split(/[,\s]+/).map((p) => p.trim()).filter(Boolean);
  const tText = parts.find((p) => p.startsWith("t="))?.slice(2) ?? "";
  if (!/^\d{1,12}$/.test(tText)) return false;
  const t = Number(tText);
  if (Math.abs(nowSeconds - t) > MAX_AGE_SECONDS) return false;
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const prefix = enc.encode(`${t}.`);
  const signed = new Uint8Array(prefix.length + raw.length);
  signed.set(prefix); signed.set(raw, prefix.length);
  const mac = hex(await crypto.subtle.sign("HMAC", key, signed));
  let ok = false;
  for (const p of parts) if (p.startsWith("v1=") && sameText(p.slice(3).toLowerCase(), mac)) ok = true;
  return ok;
}

export type Outcome = "approved" | "declined" | "needs_review" | "pending" | "other";
// subject: the provider's id for the check itself (a Persona inquiry), so one check counts as one try however many
// events describe it (the database counts a declined subject once).
export type ProviderEvent = { eventId: string; reference: string | null; outcome: Outcome; occurredAt: string | null; subject: string | null };
export type Parsed = { event: ProviderEvent } | { invalid: string };

// What every identity provider supplies. Only reading events is built; starting a check (creating an inquiry with the
// business's identity reference) is the next step once the owner has a provider account, and is not built.
export interface IdentityProvider {
  name: string;   // must equal zella_onboarding_rules().identity_provider for its events to be applied
  parseEvent(body: unknown): Parsed;
}

type Json = Record<string, unknown>;
const obj = (v: unknown): Json => (v && typeof v === "object" && !Array.isArray(v) ? v as Json : {});
const str = (v: unknown, max = 200) => (typeof v === "string" && v.length >= 1 && v.length <= max ? v : null);
const iso = (v: unknown) => { const s = str(v, 40); if (!s) return null; const d = new Date(s); return Number.isNaN(d.getTime()) ? null : d.toISOString(); };

// Persona: { data: { type: "event", id, attributes: { name: "inquiry.approved", "created-at", payload: { data: { type:
// "inquiry", id, attributes: { status, "reference-id" } } } } } }. Shape from Persona's public documentation; check it
// against a sandbox event before switching on.
// Only the decision counts as a failed check: Persona can send inquiry.failed and then inquiry.declined for the same
// inquiry, and counting both would use two of the owner's tries for one failed check. So "failed" waits (pending),
// "declined" is the countable outcome, and the database counts each inquiry (the event's subject) once. Check this
// against the provider's sandbox before switching the receiver on.
const PERSONA_STATUS: Record<string, Outcome> = {
  approved: "approved", declined: "declined", failed: "pending", needs_review: "needs_review", "needs-review": "needs_review",
  completed: "pending", pending: "pending", created: "pending", expired: "other",
};
export const persona: IdentityProvider = {
  name: "persona",
  parseEvent(body: unknown): Parsed {
    const data = obj(obj(body).data);
    const attrs = obj(data.attributes);
    const eventId = str(data.id);
    if (!eventId) return { invalid: "missing event id" };
    const inquiryData = obj(obj(attrs.payload).data);
    const inquiry = obj(inquiryData.attributes);
    const name = str(attrs.name) ?? "";
    const status = str(inquiry.status, 40) ?? name.split(".").pop() ?? "";
    const reference = str(inquiry["reference-id"], 64);
    return { event: { eventId, reference, outcome: PERSONA_STATUS[status] ?? "other", occurredAt: iso(attrs["created-at"]), subject: str(inquiryData.id) } };
  },
};

export const PROVIDERS: Record<string, IdentityProvider> = { persona };

// The database's answer (zella_identity_provider_event) -> the HTTP status the provider sees. Anything but 2xx makes
// the provider retry, which is right only when we failed.
export function statusFor(result: unknown): { status: number; text: string } {
  switch (result) {
    case "applied": case "ignored": case "unmapped": return { status: 200, text: "ok" };
    case "duplicate": return { status: 200, text: "duplicate" };
    case "off": return { status: 503, text: "not_enabled" };
    default: return { status: 500, text: "error" };
  }
}
