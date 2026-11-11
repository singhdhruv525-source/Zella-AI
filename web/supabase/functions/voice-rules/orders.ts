// The AI's lookup_order tool: the caller's order from the business's Shopify store. Pure helpers (unit-tested in
// orders_test.ts) and one function that does the lookup. Policy: docs/ORDER_LOOKUP_ASSURANCE_2026-11-05.md (revised).
//
// Neither caller ID (it can be spoofed, and a number can be shared by a household or an office) nor an email address
// (others may know it) proves who is calling. So nothing a caller hears depends on one of them alone being "proof":
//   none        no check matches             the same answer as for an order that doesn't exist
//   recipient   calling from the shipping    whether it has shipped (a gift's recipient may ask that), nothing else
//               phone only
//   one_factor  the buyer's phone OR the     whether it has shipped, or was cancelled
//               order's email
//   two_factor  the buyer's phone AND the    that, plus the day it was placed and the carrier
//               order's email
// Never said at any level: tracking numbers (not even part of one: a tracking number opens the carrier's page with the
// delivery address), payment, amounts, items, addresses, names, or anything about other orders. Tracking details go only
// to the phone or email ON THE ORDER, sent by the team (a trusted channel) - the assistant offers to take that message.
// Payment status and tracking numbers are not even fetched from the store.
export const SHOPIFY_API_VERSION = "2026-07";
type Json = Record<string, unknown>;

export const ORDER_QUERY = `query Order($q: String!) { orders(first: 1, query: $q) { nodes {
  name createdAt cancelledAt displayFulfillmentStatus phone email
  customer { phone email } shippingAddress { phone }
  fulfillments(first: 5) { status trackingInfo(first: 1) { company } } } } }`;

export const orderSearch = (orderNumber: string) => `name:#${orderNumber.replace(/^#/, "")}`;
const digits = (v: unknown) => (typeof v === "string" ? v.replace(/\D/g, "") : "");

// The phone numbers are the same: both whole numbers when both carry a country code (+...), so a number abroad never
// matches one at home that shares its last 10 digits; otherwise the last 10 digits (a store number saved without +1).
export function samePhone(a: unknown, b: unknown): boolean {
  const da = digits(a), db = digits(b);
  if (da.length < 10 || db.length < 10) return false;
  const intl = (v: unknown, d: string) => typeof v === "string" && v.trim().startsWith("+") && d.length > 10;
  if (intl(a, da) && intl(b, db)) return da === db;
  return da.slice(-10) === db.slice(-10);
}

export type Level = "none" | "recipient" | "one_factor" | "two_factor";
type OrderShape = { name?: string; createdAt?: string; cancelledAt?: string | null; displayFulfillmentStatus?: string; phone?: string; email?: string;
  customer?: { phone?: string; email?: string }; shippingAddress?: { phone?: string }; fulfillments?: { status?: string; trackingInfo?: { company?: string }[] }[] };

// Which checks match: the buyer's phone (order or customer), the shipping phone, the order's email.
export function assess(order: Json, callerNumber: string | null, email: string | null): { level: Level; buyerPhone: boolean; recipientPhone: boolean; email: boolean } {
  const o = order as OrderShape;
  const buyerPhone = !!callerNumber && [o.phone, o.customer?.phone].some((p) => samePhone(p, callerNumber));
  const recipientPhone = !buyerPhone && !!callerNumber && samePhone(o.shippingAddress?.phone, callerNumber);
  const e = (email ?? "").trim().toLowerCase();
  const mail = e.includes("@") && [o.email, o.customer?.email].some((x) => typeof x === "string" && x.trim().toLowerCase() === e);
  const level: Level = buyerPhone && mail ? "two_factor" : buyerPhone || mail ? "one_factor" : recipientPhone ? "recipient" : "none";
  return { level, buyerPhone, recipientPhone, email: mail };
}
export const callerMatches = (order: Json, callerNumber: string | null, email: string | null) => assess(order, callerNumber, email).level !== "none";

const day = (iso: unknown) => (typeof iso === "string" ? new Date(iso).toLocaleDateString("en-US", { month: "long", day: "numeric", timeZone: "UTC" }) : "");
const shipped = (o: OrderShape) => o.displayFulfillmentStatus === "FULFILLED" ? "has shipped" : o.displayFulfillmentStatus === "PARTIALLY_FULFILLED" ? "has partly shipped" : "hasn't shipped yet";
const TRUSTED = " If they want tracking details, offer to take a message so the team sends them to the phone number or email on the order (never anywhere else). For anything else (address, items, payment, refunds, changes), take a message for the team.";

// What the assistant may say at each level. Returned fields are the only order facts the assistant ever receives.
export function disclosure(order: Json, level: Level): { say: string; facts: Json } | null {
  const o = order as OrderShape;
  if (level === "none") return null;
  if (level === "recipient") {
    const s = o.cancelledAt ? "hasn't shipped" : shipped(o);   // a recipient isn't told about a cancellation: that is the buyer's
    return { say: `The order ${s}. That is all that can be shared with the person it is being sent to; the buyer can call for more, or take a message.`, facts: { shipping: s } };
  }
  const state = o.cancelledAt ? "was cancelled" : shipped(o);
  if (level === "one_factor") return { say: `Order ${o.name} ${state}.${TRUSTED}`, facts: { order: o.name, state } };
  const carrier = o.cancelledAt ? null : (o.fulfillments ?? []).flatMap((f) => f.trackingInfo ?? []).map((t) => t?.company).find(Boolean) ?? null;
  return { say: `Order ${o.name} was placed on ${day(o.createdAt)} and ${state}${carrier ? `, with ${carrier}` : ""}.${TRUSTED}`,
    facts: { order: o.name, state, placed: day(o.createdAt), carrier } };
}

// Lookups that didn't match (no order, or no check matched), counted by zella_store_lookup_context; past any limit no
// more are tried and the store isn't asked. Per call and per caller number: guessing from one phone. Per order number:
// guessing emails against one order from many phones. Per business: many phones guessing many order numbers.
export const MAX_FAILED_PER_CALL = 3, MAX_FAILED_PER_NUMBER_DAY = 6, MAX_FAILED_PER_ORDER_DAY = 5, MAX_FAILED_BUSINESS_HOUR = 30;
const LIMITED = { ok: true, status: "unverified", say: "I can't check orders on this call right now. Take a message with the order number and say the team will get back to them. Don't say whether any order exists." };
const UNVERIFIED = { ok: true, status: "unverified", say: "I couldn't confirm that order with the details I have. Ask for the email address used for the order, or take a message with the order number for the team. Don't say whether the order exists." };

// the order number as counted (never stored as given): the same for #1001 and 1001, per business
export async function orderRef(businessId: string, orderNumber: string): Promise<string> {
  const data = new TextEncoder().encode(`${businessId}:${orderNumber.replace(/^#/, "").trim().toLowerCase()}`);
  return Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", data))).map((b) => b.toString(16).padStart(2, "0")).join("").slice(0, 32);
}

type Rpc = (fn: string, args: Json) => Promise<{ data: unknown; error: unknown }>;

// Calls whose failed guess could not be recorded. The guess counters live in the database; if a failure isn't counted,
// the next lookup would see an unchanged count. Such a call gets no more lookups from this instance (fail closed).
const UNRECORDED = new Set<string>();
const UNRECORDED_MAX = 1000;
export function _resetUnrecorded() { UNRECORDED.clear(); }
// one lookup, end to end; never throws, never returns the token or order content beyond the disclosure
export async function lookupOrder(rpc: Rpc, businessId: string | null, providerCallId: string | null, args: Json, fetcher: typeof fetch = fetch, ms = 4000): Promise<Json> {
  const orderNumber = typeof args.order_number === "string" ? args.order_number : "";
  if (!orderNumber) return { ok: false, status: "need_info", say: "Ask for the order number." };
  const callKey = providerCallId ?? "";
  if (callKey && UNRECORDED.has(callKey)) return LIMITED;   // an earlier failure wasn't counted: refuse, never guess
  const ref = await orderRef(businessId ?? "", orderNumber);
  const ctx = await rpc("zella_store_lookup_context", { p_provider_call_id: providerCallId, p_business_id: businessId, p_order_ref: ref });
  const c = (ctx.data ?? {}) as Json;
  if (ctx.error || c.ok !== true) {
    return { ok: false, status: c.status === "not_available" ? "not_available" : "no_store",
      say: "Order status can't be checked right now. Take a message with the order number and say the team will get back to them." };
  }
  const write = (result: string, verified: boolean, integration: unknown) =>
    rpc("zella_store_lookup_log", { p_business_id: businessId, p_provider_call_id: providerCallId, p_integration_id: integration, p_result: result, p_verified: verified, p_order_ref: ref });
  // Records the outcome (one retry). Returns false when it could not be recorded; for a failed guess the call is then
  // refused any further lookups, because the counters it depends on did not move.
  const log = async (result: string, verified: boolean, integration: unknown = c.integration_id): Promise<boolean> => {
    let w = await write(result, verified, integration).catch((e) => ({ data: null, error: e }));
    if (w.error) w = await write(result, verified, integration).catch((e) => ({ data: null, error: e }));
    if (!w.error) return true;
    if (!verified && callKey) {
      if (UNRECORDED.size >= UNRECORDED_MAX) UNRECORDED.delete(UNRECORDED.values().next().value as string);
      UNRECORDED.add(callKey);
    }
    return false;
  };
  if (Number(c.failed_this_call ?? 0) >= MAX_FAILED_PER_CALL || Number(c.failed_this_number_day ?? 0) >= MAX_FAILED_PER_NUMBER_DAY
      || Number(c.failed_this_order_day ?? 0) >= MAX_FAILED_PER_ORDER_DAY || Number(c.failed_business_hour ?? 0) >= MAX_FAILED_BUSINESS_HOUR) {
    await log("limited", false, null);
    return LIMITED;   // Shopify is not asked
  }
  let res: Response | null = null;
  try {
    res = await fetcher(`https://${c.shop_domain}/admin/api/${SHOPIFY_API_VERSION}/graphql.json`, {
      method: "POST", headers: { "Content-Type": "application/json", "X-Shopify-Access-Token": String(c.access_token) },
      body: JSON.stringify({ query: ORDER_QUERY, variables: { q: orderSearch(orderNumber) } }), signal: AbortSignal.timeout(ms),
    });
  } catch { res = null; }
  if (!res || !res.ok) {
    await log(res && (res.status === 401 || res.status === 403) ? "store_unauthorized" : "store_error", false);
    return { ok: false, status: "store_unavailable", say: "The store couldn't be reached. Take a message with the order number and say the team will get back to them." };
  }
  const body = await res.json().catch(() => ({})) as { data?: { orders?: { nodes?: Json[] } }; errors?: unknown };
  const order = body?.data?.orders?.nodes?.[0];
  if (body.errors && !order) { await log("store_error", false); return { ok: false, status: "store_unavailable", say: "The store couldn't be checked. Take a message with the order number." }; }
  // the caller's number is the phone network's, never what is said (the assistant can't pass one: vapi-brain-tools.js)
  const caller = typeof c.caller_number === "string" ? c.caller_number : typeof args.caller_number === "string" ? args.caller_number : null;
  const a = order ? assess(order, caller, typeof args.email === "string" ? args.email : null) : null;
  const d = order && a ? disclosure(order, a.level) : null;
  if (!order || !a || !d) {   // not found and not matching: the same answer, so order numbers can't be probed
    if (!await log(order ? "unverified" : "not_found", false)) return LIMITED;
    return UNVERIFIED;
  }
  await log(`found_${a.level}`, true);   // found_recipient / found_one_factor / found_two_factor
  return { ok: true, status: "found", level: a.level, say: d.say, order: d.facts };
}
