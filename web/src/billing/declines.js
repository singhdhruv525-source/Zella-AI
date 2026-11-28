// What a card problem means to the owner, from what Stripe returns (owner question, 27 Nov 2026: wrong card details, a
// declined card, the bank's confirmation). Pure: unit tested in web/tests/addonsConsent.test.mjs.
//
//   before any charge (Stripe's fields, inline): Stripe's own words for an invalid number, a date in the past, an
//     incomplete security code, an incomplete ZIP or postal code. Pay stays disabled until the fields are valid.
//   at payment: Stripe's error on confirm. A card_error, or the bank's check failing or being closed, is a definite
//     answer: the payment failed, nothing was charged. Anything else (the connection dropped, Stripe didn't answer) is
//     unknown: the page says so and asks OUR server, never offers a second payment blindly.

// Stripe's decline codes, in our words. lost_card and stolen_card are shown as a generic decline on purpose (the
// cardholder shouldn't learn that from us; Stripe's own guidance).
// One shape for every problem (owner, 27 Nov 2026): what happened, then the next step; each specific to its case.
const GENERIC = { title: "Your card was declined", body: "Try another card. You weren't charged." };
const BY_CODE = {
  insufficient_funds: { title: "This card doesn't have enough funds", body: "Try another card. You weren't charged." },
  incorrect_cvc: { title: "The security code is incorrect", body: "Check the code on the back of your card, or try another card. You weren't charged." },
  invalid_cvc: { title: "The security code is incorrect", body: "Check the code on the back of your card, or try another card. You weren't charged." },
  expired_card: { title: "This card has expired", body: "Try another card. You weren't charged." },
  incorrect_number: { title: "The card number is incorrect", body: "Check the number, or try another card. You weren't charged." },
  processing_error: { title: "This card couldn't be processed", body: "Try again in a moment, or try another card. You weren't charged." },
};
const BANK = { title: "Your bank didn't confirm the payment", body: "You weren't charged. Try again, or try another card." };
const UNKNOWN = { title: "Checking your payment…", body: "We couldn't confirm your payment yet. Please don't pay again; we'll update this page." };

// err: what stripeEmbedded.js (or the stand in) threw: { code: "DECLINED" | "BANK_FAILED" | "UNKNOWN_OUTCOME", decline_code?, stripe_code? }
export function declineOf(err) {
  const code = String(err?.code ?? "");
  if (code === "UNKNOWN_OUTCOME") return { kind: "unknown", ...UNKNOWN };
  if (code === "BANK_FAILED" || err?.stripe_code === "payment_intent_authentication_failure") return { kind: "bank_failed", ...BANK };
  if (code === "LOCAL_CHECK") return null;   // our own check before anything reached Stripe
  if (code !== "DECLINED") return { kind: "unknown", ...UNKNOWN };
  const dc = String(err?.decline_code ?? err?.stripe_code ?? "");
  if (["lost_card", "stolen_card", "generic_decline", "card_declined", "do_not_honor", "fraudulent", "pickup_card", "restricted_card"].includes(dc)) return { kind: "declined", ...GENERIC };
  if (BY_CODE[dc]) return { kind: "declined", ...BY_CODE[dc] };
  // a card error Stripe gave without a code we know: its own message (Stripe writes these for customers), nothing charged
  if (err?.stripe_type === "card_error" || err?.decline_code || err?.stripe_code) return { kind: "declined", ...GENERIC };
  return null;   // not a decline: a local check ("Complete the card details first."), shown as it is
}

// A pack the server says failed on the saved card (failure_reason is Stripe's code): the same words.
export const savedCardDecline = (reason) => (BY_CODE[reason] ?? GENERIC);

// Stripe's own wording style for the fields' inline checks (live, Stripe's Elements show their own; the stand in mirrors these)
export const FIELD_ERRORS = {
  number_invalid: "Your card number is invalid.",
  number_incomplete: "Your card number is incomplete.",
  expiry_past: "Your card's expiration year is in the past.",
  expiry_incomplete: "Your card's expiration date is incomplete.",
  cvc_incomplete: "Your card's security code is incomplete.",
  postal_incomplete: "Your ZIP code is incomplete.",
  postal_invalid: "Your postal code is invalid.",
};
