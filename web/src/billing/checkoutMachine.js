// The glass checkout as one explicit state machine (owner, 27 Nov 2026). Pure: no React, no Stripe, no network, so
// every transition is unit tested (web/tests/glassCheckout.test.mjs). GlassCheckout.jsx renders the state and turns
// events from the server, Stripe.js and the owner into dispatches.
//
//   off ............ payments aren't switched on (the step says payment opens soon and can be passed)
//   locked ......... payment opens after an earlier step (identity)
//   idle ........... ready to pay: the summary and Pay securely
//   submitting ..... Pay pressed: asking our server for the checkout (the button is disabled)
//   loading ........ Stripe.js loading and Stripe's form mounting (a skeleton holds the space)
//   ready .......... Stripe's own form is on the page; the card is typed only there (NN-9)
//   confirming ..... Stripe finished (onComplete, or back from a redirect): asking OUR server, with backoff
//   pending ........ the backoff ran out without a confirmation: calm, never failed and never success
//   confirmed ...... the server confirmed a verified, bound payment. The only state that says paid.
//   error .......... with a kind: expired, network, stripe_load, server, misconfigured
//
// Nothing here can reach "confirmed" except the server's own answer (SERVER says confirmed); Stripe's onComplete
// only moves to "confirming".

export const STATES = ["off", "locked", "idle", "submitting", "loading", "ready", "confirming", "pending", "confirmed", "error"];
// For payments from the CRM also: needs_action (the bank wants to confirm), card_declined (the saved card was
// declined), no_card, not_payable, not_found, refused (the server's own words).
// not_taken: the server says the invoice is still payable and Stripe has no payment for it (the owner can pay again).
export const ERROR_KINDS = ["expired", "network", "stripe_load", "server", "misconfigured", "needs_action", "card_declined", "no_card", "not_payable", "not_found", "refused", "not_taken", "pack_cancelled"];

// The server's payment state (zella_owner_onboarding_payment_status) as a starting point.
export function fromServer(payment) {
  const s = String(payment?.status ?? "");
  if (s === "confirmed") return { state: "confirmed" };
  if (s === "locked") return { state: "locked" };
  if (s === "waiting" && payment?.reason === "processing") return { state: "confirming" };
  if (s === "waiting" && payment?.checkout_available === true) return { state: "idle" };
  return { state: "off" };
}

// Polling after Stripe finished: quick at first (the webhook usually lands in seconds), then slower; after the last
// step the screen shows "pending" and looks again only once a minute.
export const CONFIRM_DELAYS_MS = [1000, 2000, 3000, 5000, 8000, 13000, 20000, 30000];
export const PENDING_EVERY_MS = 60000;

const ACTIVE = new Set(["submitting", "loading", "ready", "confirming"]);   // a flow the owner started: the server's idle state never interrupts it

export function reduce(current, event) {
  const st = current?.state ?? "off";
  switch (event?.type) {
    case "SERVER": {
      // an answer without a status says nothing about the payment: the checkout stays as it is (review)
      if (!event.payment || typeof event.payment.status !== "string") return current;
      const next = fromServer(event.payment);
      if (next.state === "confirmed") return { state: "confirmed", card: event.card ?? current?.card ?? null };
      // the same answer again changes nothing (the same object), so a running backoff is never restarted
      if (next.state === "confirming") return st === "confirming" || st === "pending" ? current : { state: "confirming", attempt: 0 };
      if (next.state === "locked" || next.state === "off") return ACTIVE.has(st) ? current : next;
      // idle: keep a flow in progress, a pending wait and an error on screen until the owner acts
      return ACTIVE.has(st) || st === "pending" || st === "error" ? current : next;
    }
    case "PAY": return st === "idle" || st === "error" ? { state: "submitting" } : current;
    case "SECRET": return st === "submitting" ? { state: "loading" } : current;
    case "PROCESSING": return st === "submitting" || st === "loading" || st === "ready" ? { state: "confirming", attempt: 0 } : current;
    case "MOUNTED": return st === "loading" ? { state: "ready" } : current;
    case "COMPLETE": return st === "ready" || st === "loading" ? { state: "confirming", attempt: 0 } : current;
    case "RETURNED": return st === "confirmed" ? current : { state: "confirming", attempt: 0 };
    case "STILL_WAITING": {
      if (st !== "confirming") return current;
      const attempt = (current.attempt ?? 0) + 1;
      return attempt >= CONFIRM_DELAYS_MS.length ? { state: "pending" } : { state: "confirming", attempt };
    }
    case "ALREADY_PAID": return { state: "confirming", attempt: 0 };   // ask the server; it says confirmed, never us
    // the server says the payment stopped (a pack the bank wants confirmed, a declined saved card): a server answer,
    // so it may end a confirming wait; it never says paid
    case "STOPPED": return st === "confirmed" ? current : { state: "error", kind: ERROR_KINDS.includes(event.kind) ? event.kind : "server", ...(event.words ? { words: String(event.words) } : {}) };
    case "FAIL": {
      if (st === "confirmed") return current;
      // a lost connection while confirming isn't a failed payment: keep waiting calmly; a definite refusal from our server
      // (not the owner's, not found, can't be paid, misconfigured) ends the wait with its words (review 6)
      if (st === "confirming" || st === "pending") {
        if (event.kind === "network") return current;
        return DEFINITE.includes(event.kind) ? { state: "error", kind: event.kind, ...(event.words ? { words: String(event.words) } : {}) } : { state: "pending" };
      }
      return { state: "error", kind: ERROR_KINDS.includes(event.kind) ? event.kind : "server", ...(event.words ? { words: String(event.words) } : {}) };
    }
    case "RETRY": return st === "error" ? { state: "idle" } : current;
    // the add ons changed while Stripe's form was open (onboarding: one session per selection): back to Pay, so the next
    // start makes the session for the new total (the server expires the old one first)
    case "RESET": return st === "loading" || st === "ready" || st === "error" ? { state: "idle" } : current;
    default: return current;
  }
}

const DEFINITE = ["refused", "not_found", "not_payable", "misconfigured", "expired"];

// While confirming, the server's answer says the checkout ran out without a payment: start again (review 6).
export function expiredWhileConfirming(payment, now = Date.now()) {
  const at = Date.parse(payment?.checkout?.expires_at ?? "");
  return payment?.status === "waiting" && payment?.reason === "checkout_not_started" && Number.isFinite(at) && at < now;
}

// A key for a payment attempt is kept across a lost reply and Try again (never a second charge), and changes only after
// a definite answer that this attempt is over (review M1).
const NEW_KEY_AFTER = ["UNKNOWN_PACK", "NO_ACTIVE_PLAN", "IDEMPOTENCY_CONFLICT", "CHECKOUT_EXPIRED", "PACK_PENDING", "NO_SAVED_CARD"];
export const keyIsSpent = (err) => NEW_KEY_AFTER.includes(String(err?.code ?? ""));

// How long to wait before the next look while confirming (null when not confirming).
export function nextDelay(current) {
  if (current?.state === "confirming") return CONFIRM_DELAYS_MS[Math.min(current.attempt ?? 0, CONFIRM_DELAYS_MS.length - 1)];
  if (current?.state === "pending") return PENDING_EVERY_MS;
  return null;
}

// A failure from our server or the network, as an error kind.
export function failureKind(err) {
  const code = String(err?.code ?? "");
  if (code === "CHECKOUT_EXPIRED") return "expired";
  if (code === "PAYMENTS_MISCONFIGURED" || code === "MODE_MISMATCH") return "misconfigured";
  if (code === "STRIPE_JS") return "stripe_load";
  if (code === "ALREADY_PAID") return "already_paid";
  if (code === "NOT_FOUND") return "not_found";
  if (code === "NOT_PAYABLE") return "not_payable";
  if (code === "NO_SAVED_CARD" || code === "NO_CUSTOMER") return "no_card";
  if (["NO_ACTIVE_PLAN", "UNKNOWN_PACK", "PAYMENTS_NOT_LIVE", "MFA_REQUIRED", "NOT_ALLOWED", "BUSINESS_NOT_AVAILABLE", "PACK_PENDING", "TOO_MANY"].includes(code)) return "refused";
  const text = String(err?.message ?? "");
  if ((typeof navigator !== "undefined" && navigator.onLine === false) || /failed to fetch|network|load failed|fetch failed/i.test(text)) return "network";
  return "server";
}

// What each state says (no dashes or hyphens, US spelling, "Zella Voice" in full).
export const WORDS = {
  off: { label: "Payment opens here soon", body: "You'll pay for your plan here. Nothing is charged until then." },
  locked: { label: "Payment opens after verification", body: "You can pay once your identity is verified." },
  idle: { label: "Ready to pay", body: "Your card details go straight to Stripe." },
  submitting: { label: "Opening the card form", body: "One moment." },
  loading: { label: "Opening the card form", body: "One moment." },
  ready: { label: "Enter your card", body: "Your card details go straight to Stripe." },
  confirming: { label: "Confirming your payment", body: "This usually takes a few seconds." },
  // billing emails are held while email_live is off, so this promises only what always happens: the CRM notice
  // (zella_notify_owners "payment_received") and this page looking again by itself
  // a bank that takes its time (an authorization held, a payment processing) waits here, honestly: neither paid nor failed
  pending: { label: "Still confirming", body: "Your bank may still be approving it. Please don't pay again; we'll update this page." },
  confirmed: { label: "Payment confirmed", body: "Thank you. Your receipt is in Billing." },
};
export const ERROR_WORDS = {
  expired: { label: "This card form expired", body: "You weren't charged. Start again to get a new one.", action: "Start again" },
  network: { label: "You're offline", body: "We couldn't reach Zella Voice. Check your connection and try again.", action: "Try again" },
  stripe_load: { label: "The card form didn't load", body: "Stripe's card form couldn't open. Check your connection or turn off any ad blocker for this page.", action: "Try again" },
  server: { label: "We couldn't open the card form", body: "Something went wrong on our side. Please try again in a minute.", action: "Try again" },
  misconfigured: { label: "Payments can't open right now", body: "We've been alerted. Please try again later.", action: "Try again" },
  needs_action: { label: "Your bank wants to confirm this payment", body: "You weren't charged yet. Confirm it with your bank to finish.", action: "Confirm with your bank" },
  card_declined: { label: "Your saved card was declined", body: "You weren't charged. Pay with another card, or update your saved card.", action: "Pay with another card" },
  no_card: { label: "There's no card to charge", body: "You weren't charged. Add a card on Stripe's page, then try again.", action: "Update card" },
  not_payable: { label: "This can't be paid online", body: "You weren't charged. Contact Zella Voice support if this looks wrong.", action: null },
  not_found: { label: "We couldn't find this", body: "Check you're signed in as the business owner.", action: null },
  refused: { label: "This can't go ahead yet", body: "You weren't charged.", action: "Try again" },
  not_taken: { label: "The payment didn't go through", body: "You weren't charged. You can pay again now.", action: "Pay again" },
  // a pack purchase that ended without a charge (cancelled): final, and buying again starts a new purchase (owner, round 3)
  pack_cancelled: { label: "This add on wasn't bought", body: "You weren't charged.", action: "Try again" },
};

// Money as the server sent it: integer minor units and the plan's currency.
export function formatMoney(minor, currency = "USD") {
  const n = Number(minor);
  if (minor === null || minor === undefined || minor === "" || !Number.isFinite(n)) return "Not set";
  const code = /^[A-Za-z]{3}$/.test(String(currency ?? "")) ? String(currency).toUpperCase() : "USD";
  const value = n / 100;
  return new Intl.NumberFormat("en-US", { style: "currency", currency: code, minimumFractionDigits: Number.isInteger(value) ? 0 : 2 }).format(value);
}

// The card as Stripe reported it after a verified payment: brand and last 4 only, or nothing.
const BRANDS = { visa: "Visa", mastercard: "Mastercard", amex: "American Express", discover: "Discover", diners: "Diners Club", jcb: "JCB",
  unionpay: "UnionPay", cartes_bancaires: "Cartes Bancaires", eftpos_au: "eftpos", link: "Link" };
// A card brand code from Stripe (the card number field's change event, the PaymentMethod preview, the server) in words.
// A clean text mark, never a network logo. Unknown codes show nothing.
export const brandLabel = (code) => BRANDS[code] ?? null;

// The issuing bank only as the server passed on Stripe's `card.issuer`: plain text (React escapes it), trimmed, at most
// 40 characters; never guessed from the card number, never a logo.
export function cardWords(card) {
  const brand = BRANDS[card?.brand];
  if (!brand || !/^\d{4}$/.test(String(card?.last4 ?? ""))) return null;
  // eslint-disable-next-line no-control-regex
  const issuer = typeof card?.issuer === "string" ? card.issuer.replace(/[\u0000-\u001f\u007f]/g, "").replace(/\s+/g, " ").trim().slice(0, 40).trim() : "";
  return issuer ? { brand, last4: String(card.last4), issuer } : { brand, last4: String(card.last4) };
}
