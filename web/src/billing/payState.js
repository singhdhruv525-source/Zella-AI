// Pure: the server's answers for an invoice or a pack, in the glass checkout's terms (unit tested in web/tests).

// The server's invoice as the checkout's payment state: paid only from our record (invoice.paid applied).
// Auto pay's words (owner, 27 Nov 2026): honest about email while billing emails are held (email_live off)
export function autopayWords(emailLive, card = "this card") {
  // the switch says only what will happen (owner, 27 Nov 2026)
  void emailLive;
  return { onText: `We'll charge ${card} on each renewal date.`, offText: "You'll pay each bill yourself." };
}

// The Billing overview's "Next payment" line (review round 3): with Auto pay unknown (its lookup failed) only the amount
// and the date, never "off" or a deadline.
export function nextPaymentLine({ amount, date, apKnown, apOn, due }) {
  const head = `Next payment: ${amount} on ${date}.`;
  if (!apKnown) return head;
  return apOn ? `${head} Auto pay is on.` : `${head} Auto pay is off, so you'll pay it here by ${due}.`;
}

export function invoiceAsPayment(inv) {
  if (inv?.status === "paid") return { status: "confirmed" };
  // Stripe already has a payment for it (a reload, another tab, Auto pay at the same moment): confirming, never Pay again
  if (inv?.processing === true) return { status: "waiting", reason: "processing" };
  if (inv?.payable === true) return { status: "waiting", reason: "checkout_not_started", checkout_available: true };
  return { status: "waiting", reason: "payments_not_connected", checkout_available: false };
}

import { savedCardDecline } from "./declines.js";

// A pack purchase as the checkout's answer: granted is the only "confirmed"; a failure the owner can finish in Stripe's
// form stops the wait with its kind.
export function packAnswer(purchase) {
  if (purchase?.status === "granted") return { payment: { status: "confirmed" } };
  if (purchase?.status === "failed") {
    if (purchase.can_act && purchase.failure_reason === "authentication_required") return { payment: { status: "waiting" }, stopped: "needs_action" };
    // the saved card declined: why, in Stripe's decline code's words (insufficient funds, a code that is wrong; a lost or
    // stolen card reads as a generic decline)
    if (purchase.can_act) { const d = savedCardDecline(purchase.failure_reason); return { payment: { status: "waiting" }, stopped: "card_declined", stoppedWords: `${d.title}. ${d.body}` }; }
    return { payment: { status: "waiting" }, stopped: "no_card" };
  }
  // cancelled: a final answer, never "processing" (review round 3); Try again buys it again as a new purchase
  if (purchase?.status === "cancelled") return { payment: { status: "waiting" }, stopped: "pack_cancelled" };
  return { payment: { status: "waiting", reason: "processing" } };
}
