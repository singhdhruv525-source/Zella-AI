// A local, in-memory stand-in for the Stripe API, for tests ONLY (docs/PAYMENTS_ARCHITECTURE.md §13). It never talks
// to Stripe: it answers the calls _shared/stripe.ts makes, with the pinned version's object shapes, and records the
// events Stripe would send, which tests deliver to billing-webhook signed with a test secret (or tampered, replayed,
// reordered on purpose). Idempotency is modelled like Stripe's: the same key and body return the first answer, the same
// key with another body is an idempotency_error. No real key, card or customer data: ids are made up here.
//
//   const fake = startFakeStripe({ port: 54461 });   // fake.url is the base URL for stripeClient({ baseUrl })
//   fake.completeCheckout(sessionId)  fake.renew(subId)  fake.finalizeAndPay(invoiceId)  fake.setCard(customer, "decline")
//   await fake.deliver(webhookUrl, secret)              // posts every new event, in order, signed
import { signStripePayload } from "../../web/supabase/functions/_shared/stripe.ts";

type Json = Record<string, any>;
export type Card = "ok" | "decline" | "auth";

export interface FakeStripe {
  url: string;
  objects: Map<string, Json>;
  events: Json[];
  requests: { method: string; path: string; key: string | null; version: string | null; body: Json }[];
  now: () => number;
  advance(seconds: number): void;
  setCard(customer: string, card: Card): void;
  completeCheckout(sessionId: string): Json;
  renew(subscriptionId: string): Json;              // the next period's draft renewal invoice (invoice.created)
  finalizeAndPay(invoiceId: string): Json;          // finalise, then charge the saved card
  dispute(paymentIntent: string): Json;
  closeDispute(disputeId: string, status: "won" | "lost"): Json;
  refundOutside(paymentIntent: string, amount: number): Json;   // a refund made in the Stripe Dashboard
  emit(type: string, object: Json): Json;
  deliver(url: string, secret: string, opts?: { only?: Json[]; tamper?: boolean; at?: number }): Promise<number[]>;
  stop(): Promise<void>;
}

let seq = 0;
const id = (p: string) => `${p}_fake${(++seq).toString(36).padStart(6, "0")}`;
const MONTH = 30 * 86400, YEAR = 365 * 86400;

// a[b][0][c]=v  ->  { a: { b: [ { c: "v" } ] } }
export function parseForm(text: string): Json {
  const out: Json = {};
  for (const [k, v] of new URLSearchParams(text)) {
    const path = k.replace(/\]/g, "").split("[");
    let cur: any = out;
    path.forEach((seg, i) => {
      const last = i === path.length - 1;
      const nextIsIndex = !last && /^\d+$/.test(path[i + 1]);
      if (last) cur[seg] = v;
      else cur = cur[seg] ??= nextIsIndex ? [] : {};
    });
  }
  return out;
}

export function startFakeStripe(opts: { port?: number; livemode?: boolean } = {}): FakeStripe {
  const objects = new Map<string, Json>();
  const events: Json[] = [];
  const delivered = new Set<string>();
  const requests: FakeStripe["requests"] = [];
  const idem = new Map<string, { body: string; status: number; out: Json }>();
  const cards = new Map<string, Card>();
  let clock = Math.floor(Date.now() / 1000);
  const livemode = opts.livemode ?? false;

  const put = (o: Json) => { objects.set(o.id, o); return o; };
  const get = (oid: string) => objects.get(oid);
  const clone = (o: Json) => structuredClone(o);
  const emit = (type: string, object: Json) => {
    const e = { id: id("evt"), object: "event", type, created: clock, livemode, api_version: "2025-09-30.clover", data: { object: clone(object) } };
    events.push(e); return e;
  };
  const err = (status: number, type: string, message: string, code?: string, extra: Json = {}) => ({ status, out: { error: { type, message, code, ...extra } } });

  // ---- money helpers ----
  function charge(customer: string, amount: number, metadata: Json, invoice: string | null): Json {
    const card = cards.get(customer) ?? "ok";
    const pi = put({ id: id("pi"), object: "payment_intent", amount, currency: "usd", customer, metadata, livemode, created: clock,
      status: card === "ok" ? "succeeded" : card === "auth" ? "requires_action" : "requires_payment_method", latest_charge: null,
      last_payment_error: card === "ok" ? null : { code: card === "auth" ? "authentication_required" : "card_declined" } });
    if (card === "ok") {
      const ch = put({ id: id("ch"), object: "charge", amount, amount_refunded: 0, refunded: false, payment_intent: pi.id, customer, livemode, created: clock });
      pi.latest_charge = ch.id;
      if (!invoice) emit("payment_intent.succeeded", pi);
    } else if (!invoice) emit(card === "auth" ? "payment_intent.requires_action" : "payment_intent.payment_failed", pi);
    return pi;
  }

  function newInvoice(customer: string, sub: Json | null, reason: string, lines: Json[], period: { start: number; end: number }, status = "draft"): Json {
    const total = lines.reduce((s, l) => s + l.amount, 0);
    return put({ id: id("in"), object: "invoice", customer, status, billing_reason: reason, currency: "usd", livemode, created: clock,
      total, amount_due: total, amount_paid: 0, number: null, hosted_invoice_url: null, invoice_pdf: null, metadata: {},
      period_start: period.start, period_end: period.end, collection_method: "charge_automatically",
      parent: sub ? { type: "subscription_details", subscription_details: { subscription: sub.id, metadata: sub.metadata ?? {} } } : null,
      lines: { object: "list", data: lines, has_more: false }, payments: { object: "list", data: [] } });
  }

  function recompute(inv: Json) {
    inv.total = inv.lines.data.reduce((s: number, l: Json) => s + l.amount, 0);
    inv.amount_due = inv.total;
  }

  function pay(inv: Json): Json {
    if (inv.status === "draft") finalize(inv);
    if (inv.status !== "open") return inv;
    const sub = inv.parent?.subscription_details?.subscription ? get(inv.parent.subscription_details.subscription) : null;
    if (inv.amount_due === 0) {
      inv.status = "paid"; emit("invoice.paid", inv); return inv;
    }
    const pi = charge(inv.customer, inv.amount_due, { invoice: inv.id }, inv.id);
    inv.payments.data.push({ object: "invoice_payment", status: pi.status === "succeeded" ? "paid" : "open", payment: { type: "payment_intent", payment_intent: pi.id } });
    if (pi.status === "succeeded") {
      inv.status = "paid"; inv.amount_paid = inv.amount_due;
      if (sub && ["past_due", "incomplete"].includes(sub.status)) { sub.status = "active"; emit("customer.subscription.updated", sub); }
      emit("invoice.paid", inv); emit("payment_intent.succeeded", pi);
    } else {
      inv.attempt_count = (inv.attempt_count ?? 0) + 1;
      emit(pi.status === "requires_action" ? "invoice.payment_action_required" : "invoice.payment_failed", inv);
      if (sub && sub.status !== "past_due" && inv.billing_reason !== "subscription_update") { sub.status = "past_due"; emit("customer.subscription.updated", sub); }
    }
    return inv;
  }

  function finalize(inv: Json) {
    if (inv.status !== "draft") return inv;
    inv.status = "open"; inv.number = `ZV-${(++seq).toString().padStart(4, "0")}`;
    inv.hosted_invoice_url = `https://invoice.fake.local/${inv.id}`; inv.invoice_pdf = `https://invoice.fake.local/${inv.id}.pdf`;
    // pending invoice items of this customer go on the next invoice Stripe makes (here: when it is finalised)
    for (const ii of objects.values()) {
      if (ii.object === "invoiceitem" && ii.customer === inv.customer && !ii.invoice) {
        ii.invoice = inv.id; inv.lines.data.push({ id: id("il"), object: "line_item", amount: ii.amount, description: ii.description, metadata: ii.metadata, period: { start: clock, end: clock }, parent: { type: "invoice_item_details", invoice_item_details: { invoice_item: ii.id } } });
      }
    }
    recompute(inv);
    emit("invoice.finalized", inv);
    return inv;
  }

  const priceLine = (price: Json, qty: number, period: { start: number; end: number }) =>
    ({ id: id("il"), object: "line_item", amount: price.unit_amount * qty, metadata: {}, period, pricing: { type: "price_details", price_details: { price: price.id } } });

  // ---- API ----
  function api(method: string, path: string, b: Json): { status: number; out: Json } {
    const seg = path.split("?")[0].split("/").filter(Boolean).slice(1);   // drop "v1"
    const [r0, r1, r2] = seg;
    const ok = (o: Json) => ({ status: 200, out: clone(o) });
    const need = (oid: string | undefined, object: string) => { const o = oid ? get(oid) : undefined; return o && o.object === object ? o : null; };
    const metadata = b.metadata ?? {};
    if (method === "POST" && r0 === "customers" && !r1) return ok(put({ id: id("cus"), object: "customer", email: b.email ?? null, metadata, livemode, created: clock }));
    if (method === "POST" && r0 === "products" && !r1) return ok(put({ id: id("prod"), object: "product", name: b.name, metadata, livemode }));
    if (method === "POST" && r0 === "prices" && !r1) {
      const amount = Number(b.unit_amount);
      if (!Number.isSafeInteger(amount) || amount < 0) return err(400, "invalid_request_error", "unit_amount must be an integer", "parameter_invalid_integer");
      return ok(put({ id: id("price"), object: "price", unit_amount: amount, currency: b.currency, product: b.product, recurring: b.recurring ? { interval: b.recurring.interval } : null, metadata, livemode, active: true }));
    }
    if (r0 === "checkout" && r1 === "sessions") {
      if (method === "POST" && !r2) {
        const items = (b.line_items ?? []) as Json[];
        for (const li of items) if (!need(li.price, "price")) return err(400, "invalid_request_error", "No such price", "resource_missing");
        const amount_total = items.reduce((s, li) => s + get(li.price)!.unit_amount * Number(li.quantity ?? 1), 0);
        return ok(put({ id: id("cs"), object: "checkout.session", mode: b.mode, status: "open", payment_status: "unpaid", customer: b.customer ?? null,
          subscription: null, payment_intent: null, url: `https://checkout.fake.local/${seq}`, success_url: b.success_url, cancel_url: b.cancel_url,
          client_reference_id: b.client_reference_id ?? null, metadata, livemode, amount_total, currency: "usd", created: clock,
          _items: items, _trial_end: b.subscription_data?.trial_end ? Number(b.subscription_data.trial_end) : null, _sub_metadata: b.subscription_data?.metadata ?? {},
          _pi_metadata: b.payment_intent_data?.metadata ?? {} }));
      }
      const s = need(r2, "checkout.session");
      if (!s) return err(404, "invalid_request_error", "No such checkout session", "resource_missing");
      if (method === "POST" && seg[3] === "expire") { if (s.status === "open") { s.status = "expired"; emit("checkout.session.expired", s); } return ok(s); }
      return ok(s);
    }
    if (r0 === "subscriptions" && r1) {
      const sub = need(r1, "subscription");
      if (!sub) return err(404, "invalid_request_error", "No such subscription", "resource_missing");
      if (method === "DELETE") { if (sub.status !== "canceled") { sub.status = "canceled"; sub.canceled_at = clock; emit("customer.subscription.deleted", sub); } return ok(sub); }
      if (method === "POST") {
        if (b.cancel_at_period_end !== undefined) sub.cancel_at_period_end = b.cancel_at_period_end === "true";
        if (b.collection_method) sub.collection_method = b.collection_method;
        const newPrice = b.items?.[0]?.price;
        if (newPrice) {
          const np = need(newPrice, "price"), item = sub.items.data[0], op = get(item.price.id)!;
          if (!np) return err(400, "invalid_request_error", "No such price", "resource_missing");
          const { start, end } = { start: item.current_period_start, end: item.current_period_end };
          const t = Number(b.proration_date ?? clock);
          const diff = Math.round((np.unit_amount - op.unit_amount) * (end - t) / (end - start));
          if (b.proration_behavior === "always_invoice" && diff > 0) {
            const inv = newInvoice(sub.customer, sub, "subscription_update", [{ id: id("il"), object: "line_item", amount: diff, metadata: {}, period: { start: t, end }, pricing: { type: "price_details", price_details: { price: np.id } } }], { start: t, end });
            sub.latest_invoice = inv.id;
            pay(inv);
            if (inv.status === "paid") item.price = clone(np);
            else if (b.payment_behavior === "pending_if_incomplete") sub.pending_update = { subscription_items: [{ price: np.id }], expires_at: clock + 82800 };
          } else item.price = clone(np);
        }
        emit("customer.subscription.updated", sub);
        return ok(sub);
      }
      return ok(sub);
    }
    if (r0 === "subscription_schedules" && method === "POST" && !r1) {
      const sub = need(b.from_subscription, "subscription");
      if (!sub) return err(400, "invalid_request_error", "No such subscription", "resource_missing");
      const sch = put({ id: id("sub_sched"), object: "subscription_schedule", subscription: sub.id, phases: [], metadata, livemode, status: "active" });
      sub.schedule = sch.id; return ok(sch);
    }
    if (r0 === "subscription_schedules" && method === "POST" && r1) {
      const sch = need(r1, "subscription_schedule");
      if (!sch) return err(404, "invalid_request_error", "No such schedule", "resource_missing");
      sch.phases = b.phases ?? sch.phases; sch.end_behavior = b.end_behavior ?? sch.end_behavior; return ok(sch);
    }
    if (r0 === "invoices") {
      if (method === "POST" && r1 === "create_preview") {
        const sub = need(b.subscription, "subscription");
        if (!sub) return err(400, "invalid_request_error", "No such subscription", "resource_missing");
        const item = sub.items.data[0], op = get(item.price.id)!, np = need(b.subscription_details?.items?.[0]?.price, "price");
        if (!np) return err(400, "invalid_request_error", "No such price", "resource_missing");
        const t = Number(b.subscription_details?.proration_date ?? clock);
        const diff = Math.round((np.unit_amount - op.unit_amount) * (item.current_period_end - t) / (item.current_period_end - item.current_period_start));
        return ok({ id: `upcoming_${seq++}`, object: "invoice", total: Math.max(diff, 0), amount_due: Math.max(diff, 0), currency: "usd", livemode, lines: { data: [], has_more: false } });
      }
      if (method === "POST" && !r1) {
        const inv = newInvoice(b.customer, null, "manual", [], { start: clock, end: clock });
        inv.metadata = metadata; inv.auto_advance = b.auto_advance === "true";
        if (b.pending_invoice_items_behavior === "include") {
          for (const ii of objects.values()) if (ii.object === "invoiceitem" && ii.customer === b.customer && !ii.invoice) {
            ii.invoice = inv.id; inv.lines.data.push({ id: id("il"), object: "line_item", amount: ii.amount, description: ii.description, metadata: ii.metadata, period: { start: clock, end: clock } });
          }
          recompute(inv);
        }
        emit("invoice.created", inv); return ok(inv);
      }
      if (method === "GET" && !r1) {
        const list = [...objects.values()].filter((o) => o.object === "invoice" && (!b.customer || o.customer === b.customer) && (!b.subscription || o.parent?.subscription_details?.subscription === b.subscription));
        return ok({ object: "list", data: list.map(clone), has_more: false });
      }
      const inv = need(r1, "invoice");
      if (!inv) return err(404, "invalid_request_error", "No such invoice", "resource_missing");
      if (method === "POST" && r2 === "finalize") return ok(finalize(inv));
      if (method === "POST" && r2 === "pay") return ok(pay(inv));
      if (method === "POST" && r2 === "void") { if (inv.status === "open") { inv.status = "void"; emit("invoice.voided", inv); } return ok(inv); }
      if (method === "GET" && r2 === "lines") return ok({ object: "list", data: inv.lines.data.map(clone), has_more: false });
      return ok(inv);
    }
    if (r0 === "invoiceitems" && method === "POST" && !r1) {
      const amount = Number(b.amount);
      if (!Number.isSafeInteger(amount)) return err(400, "invalid_request_error", "amount must be an integer", "parameter_invalid_integer");
      const ii = put({ id: id("ii"), object: "invoiceitem", customer: b.customer, amount, currency: "usd", description: b.description ?? null, metadata, invoice: null, livemode });
      if (b.invoice) {
        const inv = need(b.invoice, "invoice");
        if (!inv) return err(400, "invalid_request_error", "No such invoice", "resource_missing");
        if (inv.status !== "draft") return err(400, "invalid_request_error", "Invoice is not a draft", "invoice_not_editable");
        ii.invoice = inv.id; inv.lines.data.push({ id: id("il"), object: "line_item", amount, description: ii.description, metadata, period: { start: clock, end: clock }, parent: { type: "invoice_item_details", invoice_item_details: { invoice_item: ii.id } } });
        recompute(inv);
      }
      return ok(ii);
    }
    if (r0 === "invoiceitems" && method === "GET" && !r1) return ok({ object: "list", data: [...objects.values()].filter((o) => o.object === "invoiceitem" && (!b.customer || o.customer === b.customer) && (b.pending !== "true" || !o.invoice)).map(clone), has_more: false });
    if (r0 === "payment_intents" && method === "POST" && !r1) {
      const amount = Number(b.amount);
      if (!Number.isSafeInteger(amount) || amount < 50) return err(400, "invalid_request_error", "Amount must be at least 50 cents", "amount_too_small");
      const pi = charge(b.customer, amount, metadata, null);
      if (pi.status !== "succeeded") return err(402, "card_error", "The card could not be charged", pi.last_payment_error.code, { payment_intent: clone(pi) });
      return ok(pi);
    }
    if (r0 === "payment_intents" && r1) { const pi = need(r1, "payment_intent"); return pi ? ok(pi) : err(404, "invalid_request_error", "No such payment intent", "resource_missing"); }
    if (r0 === "refunds" && method === "POST" && !r1) {
      const pi = need(b.payment_intent, "payment_intent");
      if (!pi || pi.status !== "succeeded") return err(400, "invalid_request_error", "No such charged payment", "resource_missing");
      const ch = get(pi.latest_charge)!, amount = Number(b.amount ?? ch.amount - ch.amount_refunded);
      if (!Number.isSafeInteger(amount) || amount <= 0 || amount > ch.amount - ch.amount_refunded) return err(400, "invalid_request_error", "Refund is more than the charge", "amount_too_large");
      const rf = put({ id: id("re"), object: "refund", amount, currency: "usd", payment_intent: pi.id, charge: ch.id, status: "succeeded", metadata, livemode, created: clock });
      ch.amount_refunded += amount; ch.refunded = ch.amount_refunded >= ch.amount;
      emit("refund.created", rf); emit("charge.refunded", ch); return ok(rf);
    }
    if (r0 === "refunds" && r1) { const rf = need(r1, "refund"); return rf ? ok(rf) : err(404, "invalid_request_error", "No such refund", "resource_missing"); }
    if (r0 === "refunds" && method === "GET") return ok({ object: "list", data: [...objects.values()].filter((o) => o.object === "refund" && (!b.payment_intent || o.payment_intent === b.payment_intent)).map(clone), has_more: false });
    if (r0 === "charges" && r1) { const ch = need(r1, "charge"); return ch ? ok(ch) : err(404, "invalid_request_error", "No such charge", "resource_missing"); }
    if (r0 === "disputes" && r1) { const d = need(r1, "dispute"); return d ? ok(d) : err(404, "invalid_request_error", "No such dispute", "resource_missing"); }
    if (r0 === "billing_portal" && r1 === "sessions" && method === "POST") return ok({ id: id("bps"), object: "billing_portal.session", customer: b.customer, url: `https://portal.fake.local/${seq}`, return_url: b.return_url, livemode });
    if (r0 === "events" && method === "GET" && !r1) return ok({ object: "list", data: events.filter((e) => !b.type || e.type === b.type).map(clone), has_more: false });
    if (r0 === "events" && r1) { const e = events.find((x) => x.id === r1); return e ? ok(e) : err(404, "invalid_request_error", "No such event", "resource_missing"); }
    return err(404, "invalid_request_error", `Unrecognized request URL (${method} ${path})`, "resource_missing");
  }

  const server = Deno.serve({ port: opts.port ?? 0, hostname: "127.0.0.1", onListen() {} }, async (req) => {
    const u = new URL(req.url), raw = req.method === "GET" ? u.searchParams.toString() : await req.text();
    const auth = req.headers.get("authorization") ?? "";
    const key = req.headers.get("idempotency-key");
    const body = parseForm(raw);
    requests.push({ method: req.method, path: u.pathname, key, version: req.headers.get("stripe-version"), body });
    if (!/^Bearer (sk|rk)_test_/.test(auth)) return Response.json({ error: { type: "invalid_request_error", message: "Invalid API key (the fake takes test keys only)" } }, { status: 401 });
    if (req.method !== "GET" && !key) return Response.json({ error: { type: "invalid_request_error", message: "the fake requires an Idempotency-Key on every POST" } }, { status: 400 });
    if (key) {
      const seen = idem.get(key);
      if (seen) {
        if (seen.body !== `${req.method} ${u.pathname} ${raw}`) return Response.json({ error: { type: "idempotency_error", message: "Keys for idempotent requests can only be used with the same parameters they were first used with." } }, { status: 400 });
        return Response.json(seen.out, { status: seen.status, headers: { "idempotent-replayed": "true" } });
      }
    }
    const r = api(req.method, u.pathname + (u.search ? u.search : ""), body);
    if (key && r.status < 500) idem.set(key, { body: `${req.method} ${u.pathname} ${raw}`, status: r.status, out: r.out });
    return Response.json(r.out, { status: r.status });
  });
  const addr = server.addr as Deno.NetAddr;

  return {
    url: `http://127.0.0.1:${addr.port}`, objects, events, requests,
    now: () => clock,
    advance(s) { clock += s; },
    setCard(customer, card) { cards.set(customer, card); },
    emit,
    completeCheckout(sessionId) {
      const s = get(sessionId)!;
      if (s.status !== "open") return s;
      const customer = s.customer ?? put({ id: id("cus"), object: "customer", metadata: {}, livemode, created: clock }).id;
      s.customer = customer;
      if (s.mode === "payment") {
        const amount = s.amount_total;
        const pi = charge(customer, amount, s._pi_metadata, null);
        s.payment_intent = pi.id;
        s.status = "complete"; s.payment_status = pi.status === "succeeded" ? "paid" : "unpaid";
        emit("checkout.session.completed", s);
        return s;
      }
      const items = (s._items as Json[]).map((li) => ({ price: get(li.price)!, qty: Number(li.quantity ?? 1) }));
      const recurring = items.find((i) => i.price.recurring)!, oneTime = items.filter((i) => !i.price.recurring);
      const len = recurring.price.recurring.interval === "year" ? YEAR : MONTH;
      const trial = s._trial_end as number | null;
      const start = trial ?? clock;
      const sub = put({ id: id("sub"), object: "subscription", customer, status: trial ? "trialing" : "active", cancel_at_period_end: false, livemode, created: clock,
        trial_start: trial ? clock : null, trial_end: trial, metadata: s._sub_metadata, collection_method: "charge_automatically", latest_invoice: null, pending_update: null,
        items: { object: "list", data: [{ id: id("si"), price: clone(recurring.price), quantity: recurring.qty, current_period_start: trial ? clock : start, current_period_end: trial ? trial : start + len }] } });
      const period = { start: trial ? clock : start, end: trial ? trial : start + len };
      const lines = trial ? oneTime.map((i) => priceLine(i.price, i.qty, period)) : items.map((i) => priceLine(i.price, i.qty, period));
      const inv = newInvoice(customer, sub, "subscription_create", lines, period);
      sub.latest_invoice = inv.id; s.subscription = sub.id;
      emit("customer.subscription.created", sub);
      pay(inv);
      s.status = "complete"; s.payment_status = inv.status === "paid" ? (inv.amount_paid ? "paid" : "no_payment_required") : "unpaid";
      emit("checkout.session.completed", s);
      return s;
    },
    renew(subscriptionId) {
      const sub = get(subscriptionId)!, item = sub.items.data[0];
      const len = item.price.recurring.interval === "year" ? YEAR : MONTH;
      const start = item.current_period_end, end = start + len;
      clock = Math.max(clock, start);
      if (sub.status === "trialing") { sub.status = "active"; }
      item.current_period_start = start; item.current_period_end = end;
      const inv = newInvoice(sub.customer, sub, "subscription_cycle", [priceLine(get(item.price.id)!, item.quantity ?? 1, { start, end })], { start, end });
      sub.latest_invoice = inv.id;
      emit("invoice.created", inv);
      return inv;
    },
    finalizeAndPay(invoiceId) { return clone(pay(get(invoiceId)!)); },
    dispute(paymentIntent) {
      const pi = get(paymentIntent)!;
      const d = put({ id: id("dp"), object: "dispute", amount: pi.amount, currency: "usd", charge: pi.latest_charge, payment_intent: pi.id, status: "needs_response",
        reason: "fraudulent", evidence_details: { due_by: clock + 7 * 86400 }, livemode, created: clock });
      emit("charge.dispute.created", d); return d;
    },
    closeDispute(disputeId, status) { const d = get(disputeId)!; d.status = status; emit("charge.dispute.closed", d); return d; },
    refundOutside(paymentIntent, amount) {
      const r = api("POST", "/v1/refunds", { payment_intent: paymentIntent, amount: String(amount) });
      return r.out;
    },
    async deliver(url, secret, o = {}) {
      const list = o.only ?? events.filter((e) => !delivered.has(e.id));
      const statuses: number[] = [];
      for (const e of list) {
        const raw = JSON.stringify(e);
        const sig = await signStripePayload(raw, secret, o.at);
        const res = await fetch(url, { method: "POST", headers: { "Stripe-Signature": sig, "Content-Type": "application/json" }, body: o.tamper ? raw.replace("usd", "eur") : raw });
        await res.body?.cancel();
        statuses.push(res.status);
        if (res.ok) delivered.add(e.id);
      }
      return statuses;
    },
    stop: () => server.shutdown(),
  };
}
