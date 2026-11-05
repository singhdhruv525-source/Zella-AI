// The AI's lookup_order tool: the caller's order from the business's Shopify store. Pure helpers (unit-tested in
// orders_test.ts) and one function that does the lookup. Only status and tracking are ever said; never the address,
// items or amounts. The caller must be calling from the number on the order, or give the email used for the order;
// otherwise the answer is the same whether or not the order exists.
export const SHOPIFY_API_VERSION = "2026-07";
type Json = Record<string, unknown>;

export const ORDER_QUERY = `query Order($q: String!) { orders(first: 1, query: $q) { nodes {
  name createdAt cancelledAt displayFinancialStatus displayFulfillmentStatus phone email
  customer { phone email } shippingAddress { phone }
  fulfillments(first: 5) { status trackingInfo(first: 3) { company number url } } } } }`;

export const orderSearch = (orderNumber: string) => `name:#${orderNumber.replace(/^#/, "")}`;
const digits = (v: unknown) => (typeof v === "string" ? v.replace(/\D/g, "").slice(-10) : "");

// may this caller hear about this order?
export function callerMatches(order: Json, callerNumber: string | null, email: string | null): boolean {
  const o = order as { phone?: string; email?: string; customer?: { phone?: string; email?: string }; shippingAddress?: { phone?: string } };
  const phones = [o.phone, o.customer?.phone, o.shippingAddress?.phone].map(digits).filter((d) => d.length === 10);
  const c = digits(callerNumber);
  if (c.length === 10 && phones.includes(c)) return true;
  const e = (email ?? "").trim().toLowerCase();
  return e.includes("@") && [o.email, o.customer?.email].some((x) => typeof x === "string" && x.trim().toLowerCase() === e);
}

const words = (s: unknown) => (typeof s === "string" ? s.toLowerCase().replace(/_/g, " ") : "unknown");
const day = (iso: unknown) => (typeof iso === "string" ? new Date(iso).toLocaleDateString("en-US", { month: "long", day: "numeric", timeZone: "UTC" }) : "");

// what the assistant may say: status and tracking only
export function orderSummary(order: Json): { say: string; status: Json } {
  const o = order as { name?: string; createdAt?: string; cancelledAt?: string | null; displayFinancialStatus?: string; displayFulfillmentStatus?: string;
    fulfillments?: { status?: string; trackingInfo?: { company?: string; number?: string; url?: string }[] }[] };
  const tracking = (o.fulfillments ?? []).flatMap((f) => f.trackingInfo ?? []).filter((t) => t && (t.company || t.number))[0];
  const status = { order: o.name, placed: o.createdAt, cancelled: !!o.cancelledAt, payment: words(o.displayFinancialStatus), fulfillment: words(o.displayFulfillmentStatus),
    carrier: tracking?.company ?? null, tracking_ending: tracking?.number ? tracking.number.slice(-4) : null };
  let say = `Order ${o.name} was placed on ${day(o.createdAt)}.`;
  if (o.cancelledAt) say += " It was cancelled.";
  else {
    say += ` Payment: ${status.payment}. Shipping: ${status.fulfillment}.`;
    if (tracking) say += ` It was shipped${tracking.company ? ` with ${tracking.company}` : ""}${status.tracking_ending ? `, tracking number ending ${status.tracking_ending}` : ""}.`;
  }
  return { say: say + " Only share this status; for anything else (address, items, refunds, changes), take a message for the team.", status };
}

const UNVERIFIED = { ok: true, status: "unverified", say: "I couldn't confirm that order with the details I have. Ask for the email address used for the order, or take a message with the order number for the team. Don't say whether the order exists." };

type Rpc = (fn: string, args: Json) => Promise<{ data: unknown; error: unknown }>;
// one lookup, end to end; never throws, never returns the token or order content beyond the summary
export async function lookupOrder(rpc: Rpc, businessId: string | null, providerCallId: string | null, args: Json, fetcher: typeof fetch = fetch, ms = 4000): Promise<Json> {
  const orderNumber = typeof args.order_number === "string" ? args.order_number : "";
  if (!orderNumber) return { ok: false, status: "need_info", say: "Ask for the order number." };
  const ctx = await rpc("zella_store_lookup_context", { p_provider_call_id: providerCallId, p_business_id: businessId });
  const c = (ctx.data ?? {}) as Json;
  if (ctx.error || c.ok !== true) {
    return { ok: false, status: c.status === "not_available" ? "not_available" : "no_store",
      say: "Order status can't be checked right now. Take a message with the order number and say the team will get back to them." };
  }
  const log = (result: string, verified: boolean) => rpc("zella_store_lookup_log", { p_business_id: businessId, p_provider_call_id: providerCallId, p_integration_id: c.integration_id, p_result: result, p_verified: verified });
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
  // not found and not matching get the same answer, so a caller can't probe for order numbers
  const caller = typeof c.caller_number === "string" ? c.caller_number : typeof args.caller_number === "string" ? args.caller_number : null; // the phone network's number, never what is said
  if (!order || !callerMatches(order, caller, typeof args.email === "string" ? args.email : null)) {
    await log(order ? "unverified" : "not_found", false);
    return UNVERIFIED;
  }
  await log("found", true);
  const summary = orderSummary(order);
  return { ok: true, status: "found", say: summary.say, order: summary.status };
}
