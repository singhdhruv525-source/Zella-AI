// Zella Voice: the billing worker's steps (docs/PAYMENTS_ARCHITECTURE.md §6.0b, §8). Only this code calls Stripe.
//   1. Outbox: claim rows (SKIP LOCKED, with a lease), send the STORED body with the STORED Idempotency-Key, record
//      the answer. 429, 5xx and timeouts wait and resend the same bytes; other refusals are held for a person.
//   2. Inbox: claim stored events (oldest first per subscription), fetch the object each one names from Stripe with our
//      key (fetch before grant), and hand that object to the database, which runs the binding check and applies it.
// Everything that changes money happens in one database transaction per event, guarded by unique keys.
import { type StripeClient, StripeError } from "./stripe.ts";
import { queueBillingEmails } from "./billingEmails.ts";

type Json = Record<string, unknown>;
export type Rpc = (fn: string, args: Json) => Promise<unknown>;

export function rpcClient(supabaseUrl: string, serverKey: string, fetchImpl: typeof fetch = fetch): Rpc {
  return async (fn, args) => {
    const res = await fetchImpl(`${supabaseUrl}/rest/v1/rpc/${fn}`, {
      method: "POST", signal: AbortSignal.timeout(15_000),
      headers: { "Content-Type": "application/json", apikey: serverKey, Authorization: `Bearer ${serverKey}` },
      body: JSON.stringify(args),
    });
    const text = await res.text();
    if (!res.ok) throw new Error(`rpc ${fn} failed (${res.status}): ${text.slice(0, 200)}`);
    return text ? JSON.parse(text) : null;
  };
}

const ID_RE = /^[A-Za-z0-9_]{3,255}$/;
const FETCH_PATH: Record<string, (id: string) => string> = {
  invoice: (id) => `/v1/invoices/${id}`,
  subscription: (id) => `/v1/subscriptions/${id}`,
  "checkout.session": (id) => `/v1/checkout/sessions/${id}`,
  payment_intent: (id) => `/v1/payment_intents/${id}`,
  charge: (id) => `/v1/charges/${id}`,
  refund: (id) => `/v1/refunds/${id}`,
  dispute: (id) => `/v1/disputes/${id}`,
};

type OutboxRow = { id: string; method: "POST" | "DELETE"; path: string; body: Json; idempotency_key: string };
type EventRow = { id: string; type: string; object_type: string; object_id: string; livemode: boolean; payload: Json | null };

export async function sendOutboxRow(rpc: Rpc, stripe: StripeClient, row: OutboxRow): Promise<string> {
  try {
    const out = row.method === "DELETE" ? await stripe.del(row.path, row.idempotency_key) : await stripe.post(row.path, row.body, row.idempotency_key);
    return String(await rpc("zella_billing_outbox_result", { p_id: row.id, p_ok: true, p_stripe_id: out.id, p_response: out, p_error: null, p_retryable: false, p_conflict: false }));
  } catch (e) {
    const se = e instanceof StripeError ? e : new StripeError(0, "network_error", null, "unexpected error");
    return String(await rpc("zella_billing_outbox_result", {
      p_id: row.id, p_ok: false, p_stripe_id: null, p_response: { status: se.status, type: se.type, code: se.code, decline_code: se.declineCode, payment_intent: se.paymentIntent },
      p_error: `${se.type}${se.code ? ` ${se.code}` : ""}: ${se.message}`.slice(0, 300), p_retryable: se.retryable, p_conflict: se.idempotencyConflict,
    }));
  }
}

// Runs one outbox row now (the billing API uses it so the owner gets the Checkout link at once).
export async function sendOutboxNow(rpc: Rpc, stripe: StripeClient, id: string): Promise<string> {
  const rows = (await rpc("zella_billing_outbox_claim", { p_limit: 1, p_id: id })) as OutboxRow[] | null;
  if (!rows?.length) return "not_due";
  return sendOutboxRow(rpc, stripe, rows[0]);
}

export async function fetchEventObject(stripe: StripeClient, ev: EventRow): Promise<Json> {
  if (!ID_RE.test(ev.object_id)) throw new Error("bad object id");
  // Stripe deletes only draft invoices, and a deleted one may not be retrievable: the handler checks our own row instead.
  if (ev.type === "invoice.deleted") return { id: ev.object_id, object: "invoice", deleted: true, status: ev.payload?.status ?? null, livemode: ev.livemode };
  const path = FETCH_PATH[ev.object_type];
  if (!path) throw new Error(`no fetch for ${ev.object_type}`);
  return await stripe.get(path(ev.object_id), ev.object_type === "invoice" ? { expand: ["payments"] } : undefined);
}

// Each claim gives the oldest waiting event of each subscription, so a few rounds work through a burst in order.
export async function applyEvents(rpc: Rpc, stripe: StripeClient, limit = 20, rounds = 5): Promise<Record<string, number>> {
  const counts: Record<string, number> = {};
  for (let round = 0; round < rounds; round++) {
    const rows = (await rpc("zella_stripe_claim_events", { p_limit: limit })) as EventRow[] | null;
    if (!rows?.length) break;
    await applyClaimed(rpc, stripe, rows, counts);
  }
  return counts;
}

async function applyClaimed(rpc: Rpc, stripe: StripeClient, rows: EventRow[], counts: Record<string, number>) {
  for (const ev of rows) {
    let result: string;
    try {
      const obj = await fetchEventObject(stripe, ev);
      result = String(await rpc("zella_stripe_apply_event", { p_event_id: ev.id, p_object: obj, p_key_livemode: stripe.livemode }));
    } catch (e) {
      const msg = e instanceof StripeError ? `fetch ${e.status} ${e.type}` : e instanceof Error ? e.message : "error";
      result = String(await rpc("zella_stripe_event_retry", { p_event_id: ev.id, p_error: msg.slice(0, 300) }).catch(() => "retry"));
    }
    counts[result] = (counts[result] ?? 0) + 1;
  }
}

export async function sendOutbox(rpc: Rpc, stripe: StripeClient, limit = 10): Promise<Record<string, number>> {
  const counts: Record<string, number> = {};
  const rows = (await rpc("zella_billing_outbox_claim", { p_limit: limit, p_id: null })) as OutboxRow[] | null;
  for (const row of rows ?? []) {
    const r = await sendOutboxRow(rpc, stripe, row);
    counts[r] = (counts[r] ?? 0) + 1;
  }
  return counts;
}

// One run: commands first (so a link is stored before its events arrive), then events, then any commands the events
// queued. Each step only claims what is due, so overlapping runs never send or apply anything twice.
export async function runWorkerOnce(rpc: Rpc, stripe: StripeClient): Promise<Json> {
  const outbox = await sendOutbox(rpc, stripe);
  const events = await applyEvents(rpc, stripe);
  const followUp = await sendOutbox(rpc, stripe);
  // REQ-BIL-33: 5 days past due pauses the receptionist (the database decides; nothing is called here)
  const sweep = await rpc("zella_billing_nonpayment_sweep", {}).catch(() => null);
  // billing emails: renewal and trial notices decided now, then every notice rendered into the platform outbox (held while email_live is off)
  await rpc("zella_billing_email_sweep", {}).catch(() => null);
  const emails = await queueBillingEmails(rpc).catch(() => null);
  return { outbox, events, follow_up: followUp, sweep, emails };
}
