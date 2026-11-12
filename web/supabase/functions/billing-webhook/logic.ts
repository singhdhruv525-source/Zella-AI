// Pure parts of the billing webhook (no network), tested in logic_test.ts.
// Amounts stay in the provider's integer minor units (cents, yen, fils ...); the database converts them with the
// currency's own decimals (zella_minor_to_amount). Nothing here divides by 100.

const enc = new TextEncoder();
const hex = (b: ArrayBuffer) => [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, "0")).join("");

// Compares two signatures in constant time, so the time taken gives nothing away.
export function sameText(a: string, b: string): boolean {
  const x = enc.encode(a), y = enc.encode(b);
  let diff = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

// Stripe-style "t=<unix>,v1=<hex>" signature over "<t>.<raw body>", within 5 minutes of now.
export async function verifySignature(raw: string, header: string | null, secret: string, nowSeconds = Date.now() / 1000): Promise<boolean> {
  if (!header) return false;
  const parts = header.split(",").map((p) => p.trim());
  const t = Number(parts.find((p) => p.startsWith("t="))?.slice(2));
  if (!Number.isFinite(t) || t <= 0 || Math.abs(nowSeconds - t) > 300) return false;   // old or replayed
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = hex(await crypto.subtle.sign("HMAC", key, enc.encode(`${t}.${raw}`)));
  return parts.some((p) => p.startsWith("v1=") && sameText(p.slice(3), mac));
}

const iso = (s: unknown) => (typeof s === "number" && Number.isFinite(s) ? new Date(s * 1000).toISOString() : null);
const minor = (v: unknown) => (typeof v === "number" && Number.isSafeInteger(v) && v >= 0 ? v : null);
const cur = (v: unknown) => (typeof v === "string" && /^[a-z]{3}$/i.test(v) ? v.toLowerCase() : null);
const str = (v: unknown) => (typeof v === "string" && v ? v : null);
// expandable references come either as an id or as an object with an id
const ref = (v: unknown) => (typeof v === "string" ? v : v && typeof v === "object" && typeof (v as { id?: unknown }).id === "string" ? (v as { id: string }).id : null);

type Json = Record<string, unknown>;
export type Mapped = { args: Json } | { ignore: string } | { invalid: string };

// One provider event -> the arguments of zella_process_billing_event (without provider and event id).
export function mapEvent(ev: Json): Mapped {
  const o = ((ev.data as Json | undefined)?.object ?? {}) as Json;
  const created = iso(ev.created);
  const base = { p_event_created: created };
  switch (ev.type) {
    case "invoice.payment_succeeded":
    case "invoice.payment_failed": {
      const ok = ev.type === "invoice.payment_succeeded";
      const amount = minor(ok ? o.amount_paid : o.amount_due);
      const currency = cur(o.currency);
      const payment = ref(o.payment_intent) ?? str(o.id);
      if (amount === null || !currency || !payment) return { invalid: "missing amount, currency or payment" };
      const period = ((o.lines as Json | undefined)?.data as Json[] | undefined)?.[0]?.period as Json | undefined;
      return { args: { ...base, p_type: ok ? "payment_succeeded" : "payment_failed", p_external_subscription_id: ref(o.subscription),
        p_amount_minor: amount, p_currency: currency, p_external_payment_id: payment,
        p_period_start: iso(period?.start), p_period_end: iso(period?.end),
        p_reason: ok ? null : "The card was declined or the payment could not be completed" } };
    }
    case "customer.subscription.deleted":
      if (!str(o.id)) return { invalid: "missing subscription" };
      return { args: { ...base, p_type: "subscription_cancelled", p_external_subscription_id: str(o.id) } };
    case "customer.subscription.updated":
      if (o.status !== "active") return { ignore: `subscription status ${String(o.status)}` };
      if (!str(o.id)) return { invalid: "missing subscription" };
      return { args: { ...base, p_type: "subscription_renewed", p_external_subscription_id: str(o.id),
        p_period_start: iso(o.current_period_start), p_period_end: iso(o.current_period_end) } };
    case "charge.refunded": {
      const payment = ref(o.payment_intent);
      const refunded = minor(o.amount_refunded);
      if (!payment || refunded === null) return { invalid: "missing payment or refunded amount" };
      // a full refund reverses the payment; a partial one is recorded against it
      const full = o.refunded === true || (minor(o.amount) !== null && refunded >= (o.amount as number));
      return { args: { ...base, p_type: full ? "payment_reversed" : "payment_refunded_partial", p_external_payment_id: payment,
        p_refund_minor: refunded, p_reason: full ? "Refund" : "Partial refund" } };
    }
    case "charge.dispute.created":
    case "charge.dispute.closed": {
      const payment = ref(o.payment_intent);
      if (!payment) return { invalid: "missing payment" };
      if (ev.type === "charge.dispute.created") return { args: { ...base, p_type: "payment_disputed", p_external_payment_id: payment, p_reason: "Dispute opened" } };
      if (o.status === "lost") return { args: { ...base, p_type: "payment_reversed", p_external_payment_id: payment, p_refund_minor: minor(o.amount), p_reason: "Dispute lost" } };
      if (o.status === "won") return { args: { ...base, p_type: "dispute_won", p_external_payment_id: payment, p_reason: "Dispute won" } };
      return { ignore: `dispute status ${String(o.status)}` };
    }
  }
  return { ignore: "event type not used" };
}

// The database's answer -> the HTTP status for the provider. "pending" is stored and applied later by Zella Voice
// (200, so the provider doesn't keep retrying); "failed" asks the provider to retry (500).
export function httpStatusFor(result: string): number {
  return ["processed", "pending", "duplicate", "ignored"].includes(result) ? 200 : 500;
}
