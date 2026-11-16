// Number orders (Voice & numbers > Providers): words for each state and why ordering is off. Pure: tested in
// tests/numberOrders.test.mjs.

export const ORDER_STATUS = {
  requested: ["Waiting for an owner", "warning"], approved: ["Approved", "neutral"], placing: ["Being placed", "neutral"],
  completed: ["Done", "success"], failed: ["Failed", "danger"], needs_check: ["Check at Telnyx", "danger"],
  rejected: ["Rejected", "neutral"], cancelled: ["Cancelled", "neutral"],
};
export const ORDER_KIND = { purchase: "Buy", release: "Release" };

// Why buying is off, in the order the owner fixes it; empty when it is on. The server refuses either way.
export function ordersBlocked(o) {
  if (!o) return "";
  if (!o.telnyx || !o.vapi) return "Not connected yet. The Telnyx and Vapi keys aren't both added on the server.";
  if (!o.enabled) return "Number orders are switched off. A Zella Voice owner switches them on (number_orders_enabled).";
  return "";
}

// Who may do what with one order, as offered on the page (the database decides again).
export function orderActions(row, { you, owner, manage, blocked }) {
  if (row?.status !== "requested") return { approve: false, reject: false, cancel: false };
  const decide = Boolean(owner) && row.requested_by !== you;
  return { approve: decide && !blocked, reject: decide, cancel: Boolean(manage) && (row.requested_by === you || Boolean(owner)) };
}
