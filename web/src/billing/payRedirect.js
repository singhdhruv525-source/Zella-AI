// The old /pay addresses, kept only as redirects into the CRM (owner, 27 Nov 2026: a payment opens its own page inside
// the CRM, under Settings, Billing and subscription):
//   /pay/invoice/<invoice id>   the emailed Pay now link -> /app/settings/billing/pay/<invoice id> (the CRM signs in first;
//                               the id alone grants nothing: the server answers only the invoice business's owner)
//   /pay?...&card=updated       back from Stripe's card page (older links) -> Invoices and payments
//   /pay                        -> Invoices and payments
// replace(), not a new history entry, so Back never returns to /pay. A local preview keeps its stand in scenario.
export function payRedirect(pathname, search) {
  const params = new URLSearchParams(search);
  const keep = new URLSearchParams();
  if (params.get("scenario") != null) keep.set("scenario", params.get("scenario"));
  if (params.get("card") === "updated") keep.set("card", "updated");
  // the business the link is for (an owner of several picks the right workspace; the server still checks the owner)
  if (/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(params.get("business") ?? "")) keep.set("business", params.get("business").toLowerCase());
  const q = keep.toString() ? `?${keep}` : "";
  const invoice = pathname.match(/^\/pay\/invoice\/([^/?#]+)\/?$/)?.[1];
  if (invoice) {
    // a malformed escape in the address: the invoices page, never a page stuck loading (review)
    let id = null;
    try { id = decodeURIComponent(invoice); } catch { id = null; }
    if (id !== null) return `/app/settings/billing/pay/${encodeURIComponent(id)}${q}`;
  }
  return `/app/settings/billing/invoices${q}`;
}

// A payment page's address from the CRM (Settings, Billing and subscription): the workspace goes with it (?business=), so
// the page opens in the same business for an owner of several (review); the local preview keeps its stand in scenario.
export function payPageAddress(path, businessId, search = "") {
  const q = new URLSearchParams();
  if (/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(String(businessId ?? ""))) q.set("business", String(businessId).toLowerCase());
  const scenario = new URLSearchParams(search).get("scenario");
  if (scenario != null) q.set("scenario", scenario);
  return path + (q.toString() ? `?${q}` : "");
}
