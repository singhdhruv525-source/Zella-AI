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
// args: hand to zella_process_billing_event. ignore: not used (200, nothing stored). quarantine: signed by Stripe but
// not something Zella Voice may apply (wrong account or mode, amounts that don't add up, missing fields): stored as
// type "quarantined" with the reason, applied never, answered 200 so Stripe doesn't retry it for days (C-5).
export type Mapped = { args: Json } | { ignore: string } | { quarantine: string };
// What this endpoint accepts (security audit 18 Nov 2026, M13; docs/PAYMENTS_ARCHITECTURE.md C-3, C-4): events of
// one mode (test or live) and one Stripe account, in one currency.
export type Binding = { livemode: boolean; account: string | null; currency: string };

const periodOf = (o: Json) => ((o.lines as Json | undefined)?.data as Json[] | undefined)?.[0]?.period as Json | undefined;
const planOf = (o: Json) => {
  const price = (((o.items as Json | undefined)?.data as Json[] | undefined)?.[0]?.price ?? {}) as Json;
  const key = str(price.lookup_key) ?? str((price.metadata as Json | undefined)?.zella_plan);
  return key && /^[a-z0-9_-]{1,60}$/i.test(key) ? key : null;
};

// One provider event -> the arguments of zella_process_billing_event (without provider and event id).
export function mapEvent(ev: Json, bind: Binding): Mapped {
  const o = ((ev.data as Json | undefined)?.object ?? {}) as Json;
  const created = iso(ev.created);
  const base = { p_event_created: created };
  // the binding check comes before anything is read from the object
  if (ev.livemode !== bind.livemode) return { quarantine: `livemode ${String(ev.livemode)} on a ${bind.livemode ? "live" : "test"} endpoint` };
  const account = str(ev.account);
  if (account !== bind.account && !(account === null && bind.account !== null)) return { quarantine: "another Stripe account" };
  switch (ev.type) {
    // a paid period is granted only by a paid invoice, and only when its amounts add up (C-3, C-4)
    case "invoice.paid": {
      const paid = minor(o.amount_paid), due = minor(o.amount_due), remaining = minor(o.amount_remaining), currency = cur(o.currency);
      const payment = ref(o.payment_intent) ?? ref(o.charge) ?? str(o.id);
      if (paid === null || due === null || !currency || !payment || !ref(o.subscription)) return { quarantine: "missing amount, currency, payment or subscription" };
      if (currency !== bind.currency) return { quarantine: `currency ${currency}` };
      if (o.status !== "paid" || o.paid === false || paid !== due || (remaining !== null && remaining !== 0)) return { quarantine: "the invoice is not fully paid" };
      if (paid === 0) return { ignore: "an invoice of 0 pays for nothing" };
      const period = periodOf(o);
      return { args: { ...base, p_type: "payment_succeeded", p_external_subscription_id: ref(o.subscription),
        p_amount_minor: paid, p_currency: currency, p_external_payment_id: payment,
        p_period_start: iso(period?.start), p_period_end: iso(period?.end), p_reason: str(o.billing_reason)?.slice(0, 60) ?? null } };
    }
    // invoice.paid is the grant; this one arrives alongside it and is not applied a second time
    case "invoice.payment_succeeded": return { ignore: "granted by invoice.paid" };
    case "invoice.payment_failed": {
      const amount = minor(o.amount_due), currency = cur(o.currency), payment = ref(o.payment_intent) ?? str(o.id);
      if (amount === null || !currency || !payment) return { quarantine: "missing amount, currency or payment" };
      if (currency !== bind.currency) return { quarantine: `currency ${currency}` };
      // past due: the subscription is marked by the failed payment; nothing is granted
      return { args: { ...base, p_type: "payment_failed", p_external_subscription_id: ref(o.subscription),
        p_amount_minor: amount, p_currency: currency, p_external_payment_id: payment,
        p_reason: "The card was declined or the payment could not be completed" } };
    }
    // the first payment is granted by its invoice.paid, never by the session (which only says the form was finished)
    case "checkout.session.completed": return { ignore: "granted by invoice.paid" };
    case "customer.subscription.deleted":
      if (!str(o.id)) return { quarantine: "missing subscription" };
      return { args: { ...base, p_type: "subscription_cancelled", p_external_subscription_id: str(o.id) } };
    case "customer.subscription.updated": {
      // a status alone grants nothing (C-3): no period is ever opened from this event
      if (!str(o.id)) return { quarantine: "missing subscription" };
      if (o.status === "incomplete_expired" || o.status === "canceled") return { args: { ...base, p_type: "subscription_cancelled", p_external_subscription_id: str(o.id) } };
      // a plan change or downgrade changes the plan only; what it costs comes with the next paid invoice
      const prev = ((ev.data as Json | undefined)?.previous_attributes ?? {}) as Json;
      const plan = planOf(o);
      if ("items" in prev && plan) return { args: { ...base, p_type: "plan_changed", p_external_subscription_id: str(o.id), p_plan_slug: plan } };
      // past_due and unpaid arrive with invoice.payment_failed, which records them; active comes with invoice.paid
      return { ignore: `subscription status ${String(o.status)}` };
    }
    case "charge.refunded": {
      const payment = ref(o.payment_intent);
      const refunded = minor(o.amount_refunded);
      if (!payment || refunded === null) return { quarantine: "missing payment or refunded amount" };
      // a full refund reverses the payment; a partial one is recorded against it (a Dashboard refund alerts Zella Voice in the database)
      const full = o.refunded === true || (minor(o.amount) !== null && refunded >= (o.amount as number));
      return { args: { ...base, p_type: full ? "payment_reversed" : "payment_refunded_partial", p_external_payment_id: payment,
        p_refund_minor: refunded, p_reason: full ? "Refund" : "Partial refund" } };
    }
    case "charge.dispute.created":
    case "charge.dispute.closed": {
      const payment = ref(o.payment_intent);
      if (!payment) return { quarantine: "missing payment" };
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
