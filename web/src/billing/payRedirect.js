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
  const q = keep.toString() ? `?${keep}` : "";
  const invoice = pathname.match(/^\/pay\/invoice\/([^/?#]+)\/?$/)?.[1];
  if (invoice) return `/app/settings/billing/pay/${encodeURIComponent(decodeURIComponent(invoice))}${q}`;
  return `/app/settings/billing/invoices${q}`;
}
