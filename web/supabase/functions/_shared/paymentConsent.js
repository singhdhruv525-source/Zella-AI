// Zella Voice: the words of the required "I agree" box before Pay (owner decision, 27 Nov 2026), shared by the pages that
// show it (web/src/billing) and billing-api, which rebuilds them from the server's own figures. The database rebuilds
// them too (sql/zella_stripe_owner_pay.sql, zella_billing_consent_text) and refuses a payment whose sha256 differs; a
// test keeps the three the same (tests/stripe_owner_pay/stub_run.sh). Plain text only: the page links "Terms" and
// "Privacy Policy" inside these exact words, and the sha256 is of these words.
//
//   kind "plan"  the onboarding payment or Pay now. With Auto pay on, the plan's renewal price ($Y) recurs; add ons
//                never do, and the words say so when there are any.
//   kind "pack"  one add on on its own (the pack page, or finishing a pack in Stripe's form).

export const TERMS_PREFIX = "I agree to the Terms and Privacy Policy";

// Whole dollars without cents ("$249"), otherwise two decimals ("$29.50"); thousands with commas (the database's
// zella_billing_consent_money writes the same).
export function consentMoney(minor) {
  if (minor === null || minor === undefined || minor === "" || typeof minor === "boolean") return null;   // a missing figure is never "$0"
  const n = Number(minor);
  if (!Number.isInteger(n) || n < 0) return null;
  const dollars = Math.floor(n / 100), cents = n % 100;
  const whole = String(dollars).replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  return cents === 0 ? `$${whole}` : `$${whole}.${String(cents).padStart(2, "0")}`;
}

// The exact words, or null when a figure is missing (the box then can't be ticked and nothing can start).
export function consentText({ kind = "plan", todayMinor, autopay = true, renewalMinor = null, addons = false }) {
  const today = consentMoney(todayMinor);
  if (!today) return null;
  const head = `${TERMS_PREFIX} and authorize Zella Voice to charge this card ${today} today`;
  if (kind === "pack") return `${head} for this add on.`;
  let text;
  if (autopay) {
    const renewal = consentMoney(renewalMinor);
    if (!renewal) return null;
    text = `${head} and ${renewal} on each renewal until I cancel.`;
  } else {
    text = `${head}. I'll pay future invoices myself.`;
  }
  return addons ? `${text} Add ons are one time and never renew.` : text;
}

// sha256 of the words, lower case hex (Web Crypto: the browser, Deno and Node all have it).
export async function consentHash(text) {
  const bytes = new TextEncoder().encode(String(text));
  const digest = await globalThis.crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}
