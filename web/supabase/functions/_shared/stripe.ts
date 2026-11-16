// Zella Voice: the one Stripe client (server side only; docs/PAYMENTS_ARCHITECTURE.md §16.2, §8.1).
// Plain fetch to Stripe's REST API, form encoded, with the API version pinned, a 10 s timeout and an Idempotency-Key on
// every POST. The base URL is injectable, so tests run against the local fake (tests/stripe_fake); nothing in the tests
// ever reaches api.stripe.com. The key comes from STRIPE_SECRET_KEY in the edge secrets and is never logged.
// Amounts stay integer cents; nothing here divides or multiplies money.

// Pinned on purpose; changing it is a reviewed change, proven in the sandbox first (§16, §16.8).
// Confirm in the Stripe sandbox: the version name, and that the webhook endpoints are pinned to the same one.
export const STRIPE_API_VERSION = "2025-09-30.clover";
export const STRIPE_DEFAULT_BASE = "https://api.stripe.com";

type Json = Record<string, unknown>;
export type StripeObject = Json & { id: string; object?: string };

export class StripeError extends Error {
  constructor(
    readonly status: number,          // HTTP status, 0 for network or timeout
    readonly type: string,            // Stripe error type, or "network_error"
    readonly code: string | null,     // Stripe error code (card_declined, authentication_required, ...)
    message: string,
    readonly declineCode: string | null = null,
    readonly paymentIntent: string | null = null,
  ) { super(message); this.name = "StripeError"; }
  // The outbox resends the SAME stored body with the SAME key only for these (§8: 429, 5xx, timeout).
  get retryable(): boolean { return this.status === 0 || this.status === 429 || this.status >= 500; }
  // A key reused with a different body is a bug: held and alerted, never a new key automatically (§8.1 rule 4).
  get idempotencyConflict(): boolean { return this.type === "idempotency_error" || this.code === "idempotency_key_in_use"; }
}

// Stripe's form encoding: a[b]=1, a[c][0][d]=2. Booleans as true/false, null and undefined left out.
export function formEncode(params: Json, prefix = "", out: URLSearchParams = new URLSearchParams()): URLSearchParams {
  for (const [k, v] of Object.entries(params)) {
    if (v === undefined || v === null) continue;
    const key = prefix ? `${prefix}[${k}]` : k;
    if (Array.isArray(v)) {
      v.forEach((item, i) => {
        if (item !== null && typeof item === "object") formEncode(item as Json, `${key}[${i}]`, out);
        else out.append(`${key}[${i}]`, String(item));
      });
    } else if (typeof v === "object") formEncode(v as Json, key, out);
    else out.append(key, String(v));
  }
  return out;
}

export interface StripeClientOptions {
  secretKey: string;
  baseUrl?: string;
  apiVersion?: string;
  timeoutMs?: number;
  fetchImpl?: typeof fetch;
}

export interface StripeClient {
  readonly livemode: boolean;
  get(path: string, query?: Json): Promise<StripeObject>;
  post(path: string, params: Json, idempotencyKey: string): Promise<StripeObject>;
  del(path: string, idempotencyKey: string): Promise<StripeObject>;
}

const KEY_RE = /^[\x21-\x7e]{1,255}$/;   // printable ASCII, at most 255 (§16.2); our keys carry ids only, no personal data

// sk_live_ / rk_live_ keys are live mode; anything else (sk_test_, rk_test_) is the sandbox. Events and objects must
// match it (§6.0a), so a sandbox event can never grant in live and the reverse.
export function keyIsLive(secretKey: string): boolean {
  return /^(sk|rk)_live_/.test(secretKey);
}

export function stripeClient(opts: StripeClientOptions): StripeClient {
  if (!opts.secretKey) throw new Error("STRIPE_SECRET_KEY is not set");
  const base = (opts.baseUrl ?? STRIPE_DEFAULT_BASE).replace(/\/+$/, "");
  const f = opts.fetchImpl ?? fetch;
  const timeout = opts.timeoutMs ?? 10_000;
  const version = opts.apiVersion ?? STRIPE_API_VERSION;

  async function call(method: string, path: string, body: URLSearchParams | null, idempotencyKey?: string): Promise<StripeObject> {
    if (!path.startsWith("/v1/")) throw new Error("Stripe paths start with /v1/");
    if (method !== "GET" && (!idempotencyKey || !KEY_RE.test(idempotencyKey))) throw new Error("every Stripe POST needs an Idempotency-Key");
    const headers: Record<string, string> = { Authorization: `Bearer ${opts.secretKey}`, "Stripe-Version": version };
    if (body) headers["Content-Type"] = "application/x-www-form-urlencoded";
    if (idempotencyKey) headers["Idempotency-Key"] = idempotencyKey;
    let res: Response;
    try {
      res = await f(`${base}${path}`, { method, headers, body: body?.toString(), signal: AbortSignal.timeout(timeout) });
    } catch (e) {
      throw new StripeError(0, "network_error", null, e instanceof Error && e.name === "TimeoutError" ? "Stripe timed out" : "Stripe could not be reached");
    }
    let data: Json;
    try { data = await res.json(); } catch { throw new StripeError(res.status || 502, "api_error", null, "Stripe answered with something that is not JSON"); }
    if (!res.ok) {
      const err = (data.error ?? {}) as Json;
      const pi = err.payment_intent as Json | undefined;
      throw new StripeError(res.status, String(err.type ?? "api_error"), (err.code as string) ?? null,
        String(err.message ?? `Stripe answered ${res.status}`), (err.decline_code as string) ?? null, (pi?.id as string) ?? null);
    }
    if (typeof data.id !== "string" && data.object !== "list") throw new StripeError(502, "api_error", null, "Stripe answered without an object id");
    return data as StripeObject;
  }

  return {
    livemode: keyIsLive(opts.secretKey),
    get: (path, query) => {
      const q = query ? formEncode(query).toString() : "";
      return call("GET", q ? `${path}?${q}` : path, null);
    },
    post: (path, params, key) => call("POST", path, formEncode(params), key),
    del: (path, key) => call("DELETE", path, null, key),
  };
}

// ---------------------------------------------------------------------------------------------------------------
// Webhook signatures (§16.4): Stripe-Signature "t=<unix>,v1=<hex>[,v1=...]", HMAC-SHA256(endpoint secret, "<t>.<raw>").
// Every v1 is compared in constant time; v0 and anything else is ignored; t must be within the tolerance of now.
// ---------------------------------------------------------------------------------------------------------------
const enc = new TextEncoder();
const hex = (b: ArrayBuffer) => [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, "0")).join("");

export function sameText(a: string, b: string): boolean {
  const x = enc.encode(a), y = enc.encode(b);
  let diff = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

export async function hmacHex(secret: string, text: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return hex(await crypto.subtle.sign("HMAC", key, enc.encode(text)));
}

export const SIGNATURE_TOLERANCE_SECONDS = 300;

// secrets: one, or two during a planned rotation overlap (§9). Returns the signed timestamp, or null when invalid.
export async function verifyStripeSignature(raw: string, header: string | null, secrets: string[],
  nowSeconds = Date.now() / 1000, tolerance = SIGNATURE_TOLERANCE_SECONDS): Promise<number | null> {
  if (!header || header.length > 2000) return null;
  const parts = header.split(",").map((p) => p.trim());
  const ts = parts.filter((p) => p.startsWith("t="));
  if (ts.length !== 1 || !/^t=\d{1,12}$/.test(ts[0])) return null;
  const t = Number(ts[0].slice(2));
  if (Math.abs(nowSeconds - t) > tolerance) return null;   // too old (or from the future): a replay or a bad clock
  const given = parts.filter((p) => p.startsWith("v1=")).map((p) => p.slice(3));
  if (!given.length) return null;
  let ok = false;
  for (const s of secrets.filter(Boolean)) {
    const mac = await hmacHex(s, `${t}.${raw}`);
    for (const g of given) ok = sameText(g, mac) || ok;   // no early exit: every comparison runs
  }
  return ok ? t : null;
}

// Tests and the fake sign events the same way Stripe does.
export async function signStripePayload(raw: string, secret: string, t = Math.floor(Date.now() / 1000)): Promise<string> {
  return `t=${t},v1=${await hmacHex(secret, `${t}.${raw}`)}`;
}

// ---------------------------------------------------------------------------------------------------------------
// Field access that works on the pinned version and on the older invoice shape (Stripe moved invoice.subscription to
// invoice.parent.subscription_details and the subscription period onto its items in 2025). Confirm in the sandbox.
// ---------------------------------------------------------------------------------------------------------------
export const ref = (v: unknown): string | null =>
  typeof v === "string" && v ? v : v && typeof v === "object" && typeof (v as Json).id === "string" ? (v as Json).id as string : null;

export function invoiceSubscription(inv: Json): string | null {
  const parent = inv.parent as Json | undefined;
  return ref((parent?.subscription_details as Json | undefined)?.subscription) ?? ref(inv.subscription);
}

export function invoicePaymentIntent(inv: Json): string | null {
  const direct = ref(inv.payment_intent);
  if (direct) return direct;
  const pays = ((inv.payments as Json | undefined)?.data ?? []) as Json[];
  const paid = pays.find((p) => p.status === "paid") ?? pays[0];
  return ref((paid?.payment as Json | undefined)?.payment_intent);
}

export function linePrice(line: Json): string | null {
  const pd = (line.pricing as Json | undefined)?.price_details as Json | undefined;
  return ref(pd?.price) ?? ref(line.price);
}

export function subscriptionPeriod(sub: Json): { start: number | null; end: number | null } {
  const item = (((sub.items as Json | undefined)?.data ?? []) as Json[])[0] ?? {};
  const n = (v: unknown) => (typeof v === "number" && Number.isSafeInteger(v) ? v : null);
  return { start: n(item.current_period_start) ?? n(sub.current_period_start), end: n(item.current_period_end) ?? n(sub.current_period_end) };
}
