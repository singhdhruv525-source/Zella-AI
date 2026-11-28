// Zella Voice: the words of the required "I agree" box before Pay (owner decision, 27 Nov 2026), shared by the pages that
// show it (web/src/billing) and billing-api, which rebuilds them from the server's own figures. The database rebuilds
// them too (sql/zella_stripe_owner_pay.sql, zella_billing_consent_text) and refuses a payment whose sha256 differs; a
// test keeps the three the same (tests/stripe_owner_pay/stub_run.sh). Plain text only: the page links "Terms" and
// "Privacy Policy" inside these exact words, and the sha256 is of these words.
//
//   With Auto pay on, the plan's renewal price ($Y) recurs; add ons never do, and the words say so when there are any.

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
//   plan     the onboarding payment (todayMinor: the plan, the setup fee and any add ons) or Pay now without add ons
//   invoice  Pay now with add ons: the plan on this card, the add ons on the saved card right after
//   pack     one add on on its own
export function consentText({ kind = "plan", todayMinor, autopay = true, renewalMinor = null, addonsMinor = 0 }) {
  const today = consentMoney(todayMinor);
  if (!today) return null;
  if (kind === "pack") return `${TERMS_PREFIX} and authorize Zella Voice to charge ${today} today for this add on.`;
  const extra = Number(addonsMinor ?? 0);
  if (!Number.isInteger(extra) || extra < 0) return null;
  const renewal = autopay ? consentMoney(renewalMinor) : "";
  if (autopay && !renewal) return null;
  const head = kind === "invoice" && extra > 0
    ? `${TERMS_PREFIX} and authorize Zella Voice to charge ${today} to this card and ${consentMoney(extra)} for add ons to my saved card today`
    : `${TERMS_PREFIX} and authorize Zella Voice to charge this card ${today} today`;
  const sep = kind === "invoice" && extra > 0 ? "," : "";
  const text = autopay ? `${head}${sep} and ${renewal} each renewal until I cancel.` : `${head}.`;
  return extra > 0 ? `${text} Add ons are one time.` : text;
}

// sha256 of the words, lower case hex (Web Crypto: the browser, Deno and Node all have it).
export async function consentHash(text) {
  const bytes = new TextEncoder().encode(String(text));
  const digest = await globalThis.crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}
