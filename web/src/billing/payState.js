// Pure: the server's answers for an invoice or a pack, in the glass checkout's terms (unit tested in web/tests).

// The server's invoice as the checkout's payment state: paid only from our record (invoice.paid applied).
// Auto pay's words (owner, 27 Nov 2026): honest about email while billing emails are held (email_live off)
export function autopayWords(emailLive, card = "this card") {
  return { onText: `Stripe charges ${card} on each renewal date.`,
    offText: emailLive ? "We'll email your invoice; pay it within 3 days in the CRM." : "Your invoice appears in the CRM; pay it there within 3 days." };
}

export function invoiceAsPayment(inv) {
  if (inv?.status === "paid") return { status: "confirmed" };
  if (inv?.payable === true) return { status: "waiting", reason: "checkout_not_started", checkout_available: true };
  return { status: "waiting", reason: "payments_not_connected", checkout_available: false };
}

// A pack purchase as the checkout's answer: granted is the only "confirmed"; a failure the owner can finish in Stripe's
// form stops the wait with its kind.
export function packAnswer(purchase) {
  if (purchase?.status === "granted") return { payment: { status: "confirmed" } };
  if (purchase?.status === "failed") {
    if (purchase.can_act && purchase.failure_reason === "authentication_required") return { payment: { status: "waiting" }, stopped: "needs_action" };
    if (purchase.can_act) return { payment: { status: "waiting" }, stopped: "card_declined" };
    return { payment: { status: "waiting" }, stopped: "no_card" };
  }
  return { payment: { status: "waiting", reason: "processing" } };
}
