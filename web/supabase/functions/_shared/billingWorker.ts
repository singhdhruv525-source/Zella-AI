// Zella Voice: the billing worker's steps (docs/PAYMENTS_ARCHITECTURE.md §6.0b, §8). Only this code calls Stripe.
//   1. Outbox: claim rows (SKIP LOCKED, with a lease), send the STORED body with the STORED Idempotency-Key, record
//      the answer. 429, 5xx and timeouts wait and resend the same bytes; other refusals are held for a person.
//   2. Inbox: claim stored events (oldest first per subscription), fetch the object each one names from Stripe with our
//      key (fetch before grant), and hand that object to the database, which runs the binding check and applies it.
// Everything that changes money happens in one database transaction per event, guarded by unique keys.
import { type StripeClient, StripeError, type StripeObject } from "./stripe.ts";
import { queueBillingEmails } from "./billingEmails.ts";

type Json = Record<string, any>;
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

type OutboxRow = { id: string; method: "POST" | "DELETE"; path: string; body: Json; idempotency_key: string; attempts: number };

// A step that may fail without stopping the run: the failure is logged by step name (never a secret or a body).
const soft = <T>(step: string, p: Promise<T>): Promise<T | null> =>
  p.catch((e) => { console.error("billing worker step failed", step, e instanceof Error ? e.message.slice(0, 200) : "error"); return null; });
type EventRow = { id: string; type: string; object_type: string; object_id: string; livemode: boolean; payload: Json | null };

// Stripe's answer and its recording are kept apart: a failure to RECORD a success is never reported as a Stripe
// failure (the row stays "sending", its lease lapses and the same key is sent again, so Stripe answers the same).
// Each result names the claim's attempt number, so a late answer from an earlier claim changes nothing.
export async function sendOutboxRow(rpc: Rpc, stripe: StripeClient, row: OutboxRow): Promise<string> {
  let out: StripeObject;
  try {
    out = row.method === "DELETE" ? await stripe.del(row.path, row.idempotency_key) : await stripe.post(row.path, row.body, row.idempotency_key);
  } catch (e) {
    const se = e instanceof StripeError ? e : new StripeError(0, "network_error", null, "unexpected error");
    return String(await rpc("zella_billing_outbox_result", {
      p_id: row.id, p_ok: false, p_stripe_id: null, p_response: { status: se.status, type: se.type, code: se.code, decline_code: se.declineCode, payment_intent: se.paymentIntent },
      p_error: `${se.type}${se.code ? ` ${se.code}` : ""}: ${se.message}`.slice(0, 300), p_retryable: se.retryable, p_conflict: se.idempotencyConflict,
      p_attempt: row.attempts,
    }));
  }
  return String(await rpc("zella_billing_outbox_result", {
    p_id: row.id, p_ok: true, p_stripe_id: out.id, p_response: out, p_error: null, p_retryable: false, p_conflict: false, p_attempt: row.attempts,
  }));
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

// §10, §12: events the webhook missed are read from Stripe's Events API and stored exactly as the webhook stores them
// (repeats are ignored), and once a day Stripe's invoices, refunds and disputes of the last 7 days are matched to our
// rows. Nothing is corrected here: the database records each difference as an alert for a person.
// The scan reads every page since the watermark (less an hour of overlap); only a scan that reached the last page
// (has_more false) moves the watermark, to when this scan started. A scan cut short at maxPages moves nothing and the
// database raises an alert: a longer backfill is a separate, manual step a person approves.
export async function reconcile(rpc: Rpc, stripe: StripeClient, nowSeconds = Math.floor(Date.now() / 1000), maxPages = 50): Promise<Json> {
  const out: Json = {};
  const since = Number(await rpc("zella_billing_events_cursor", {}));
  let stored = 0, starting: string | undefined, complete = false;
  for (let page = 0; page < maxPages; page++) {
    const list = await stripe.get("/v1/events", { created: { gte: since }, limit: 100, ...(starting ? { starting_after: starting } : {}) });
    const data = (list.data ?? []) as Json[];
    for (const ev of data) if ((await rpc("zella_stripe_event_store", { p_event: ev, p_key_livemode: stripe.livemode })) === "stored") stored++;
    if (!list.has_more || !data.length) { complete = true; break; }
    starting = String(data[data.length - 1].id);
  }
  await rpc("zella_billing_events_scanned", { p_started: nowSeconds, p_stored: stored, p_complete: complete });
  out.events_recovered = stored;
  out.events_scan_complete = complete;
  if ((await rpc("zella_billing_reconcile_due", {})) === true) {
    const week = nowSeconds - 7 * 86400, objects: Json[] = [];
    for (const [type, path] of [["invoice", "/v1/invoices"], ["refund", "/v1/refunds"], ["dispute", "/v1/disputes"]] as const) {
      const list = await stripe.get(path, { created: { gte: week }, limit: 100 });
      for (const o of (list.data ?? []) as Json[]) {
        objects.push({ type, id: o.id, customer: o.customer ?? null, payment_intent: o.payment_intent ?? null, status: o.status,
          amount: type === "invoice" ? o.amount_paid : o.amount, livemode: o.livemode });
      }
    }
    out.objects = await rpc("zella_billing_reconcile_objects", { p_objects: objects });
    out.ledger = await rpc("zella_billing_ledger_check", {});
  }
  return out;
}

export async function sendOutbox(rpc: Rpc, stripe: StripeClient, limit = 10): Promise<Record<string, number>> {
  const counts: Record<string, number> = {};
  const rows = (await rpc("zella_billing_outbox_claim", { p_limit: limit, p_id: null })) as OutboxRow[] | null;
  for (const row of rows ?? []) {
    // one row that can't be recorded never stops the others
    const r = await soft("outbox_row", sendOutboxRow(rpc, stripe, row)) ?? "record_failed";
    counts[r] = (counts[r] ?? 0) + 1;
  }
  return counts;
}

// One run: commands first (so a link is stored before its events arrive), then events, then any commands the events
// queued. Each step only claims what is due, so overlapping runs never send or apply anything twice.
export async function runWorkerOnce(rpc: Rpc, stripe: StripeClient): Promise<Json> {
  // each step runs even if the one before failed (logged by name)
  const outbox = await soft("outbox", sendOutbox(rpc, stripe));
  const events = await soft("events", applyEvents(rpc, stripe));
  const followUp = await soft("outbox_follow_up", sendOutbox(rpc, stripe));
  // REQ-BIL-33: 5 days past due pauses the receptionist (the database decides; nothing is called here)
  const sweep = await soft("nonpayment_sweep", rpc("zella_billing_nonpayment_sweep", {}));
  // billing emails: renewal and trial notices decided now, then every notice rendered into the platform outbox (held while email_live is off)
  await soft("email_sweep", rpc("zella_billing_email_sweep", {}));
  const emails = await soft("billing_emails", queueBillingEmails(rpc));
  const recon = await soft("reconcile", reconcile(rpc, stripe));
  return { outbox, events, follow_up: followUp, sweep, emails, reconcile: recon };
}
