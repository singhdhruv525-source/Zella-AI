// Stripe.js for Embedded Checkout, loaded only when it is needed: on the Pay step, with payments live, after the owner
// pressed Pay and our server returned a checkout. Never in the stand in path (the stand in api brings its own mount).
//
// Loaded once, from https://js.stripe.com only, on the release that matches our pinned API version (2025-09-30.clover:
// js.stripe.com/clover/stripe.js; docs/PAYMENTS_ARCHITECTURE.md §16.10). Stripe requires it to be loaded directly from
// js.stripe.com, never bundled or hosted by us (the @stripe/stripe-js README, "to be PCI compliant"), and serves updates
// at that same address, so a fixed Subresource Integrity hash would break it: no SRI. The CSP allows js.stripe.com.
// The client secret stays in memory: it is handed to Stripe.js here and never written to the address bar, storage,
// logs or error reports.

export const STRIPE_JS_URL = "https://js.stripe.com/clover/stripe.js";
const LOAD_TIMEOUT_MS = 15000;
let loading = null;
let current = null;   // the one embedded instance on the page (Stripe allows one at a time)

const fail = (code, message) => Object.assign(new Error(message), { code });

export function loadStripeJs(doc = globalThis.document) {
  if (globalThis.Stripe) return Promise.resolve(globalThis.Stripe);
  if (loading) return loading;
  loading = new Promise((resolve, reject) => {
    const script = doc.createElement("script");
    script.src = STRIPE_JS_URL;
    script.async = true;
    const timer = setTimeout(() => done(fail("STRIPE_JS", "Stripe.js timed out")), LOAD_TIMEOUT_MS);
    function done(err) {
      clearTimeout(timer);
      if (err || !globalThis.Stripe) { loading = null; script.remove(); reject(err ?? fail("STRIPE_JS", "Stripe.js didn't start")); }
      else resolve(globalThis.Stripe);
    }
    script.addEventListener("load", () => done(null));
    script.addEventListener("error", () => done(fail("STRIPE_JS", "Stripe.js didn't load")));
    doc.head.appendChild(script);
  });
  return loading;
}

// A publishable key's mode must match the server's key mode: a test form never opens a live session, or the reverse.
export function checkKeyMode(publishableKey, livemode) {
  const live = /^pk_live_[A-Za-z0-9]+$/.test(String(publishableKey ?? "")), test = /^pk_test_[A-Za-z0-9]+$/.test(String(publishableKey ?? ""));
  if (!live && !test) throw fail("MODE_MISMATCH", "not a publishable key");
  if (typeof livemode !== "boolean") throw fail("MODE_MISMATCH", "the server didn't say which mode its key is in");
  if (live !== (livemode === true)) throw fail("MODE_MISMATCH", "the publishable key and the server's key are in different modes");
}

// Mounts Stripe's Embedded Checkout into el. Returns { destroy }. onComplete runs when Stripe says the session is
// complete: that only starts "confirming"; the server decides whether it is paid.
export async function mountEmbeddedCheckout(el, { clientSecret, publishableKey, livemode, onComplete }) {
  checkKeyMode(publishableKey, livemode);
  const Stripe = await loadStripeJs();
  destroyCurrent();
  let instance;
  try {
    const stripe = Stripe(publishableKey);
    instance = await stripe.initEmbeddedCheckout({ fetchClientSecret: () => Promise.resolve(clientSecret), onComplete });
  } catch {
    throw fail("STRIPE_JS", "Stripe's form couldn't start");   // never pass Stripe's own error text on: it can carry ids
  }
  instance.mount(el);
  current = instance;
  return { destroy: () => { if (current === instance) destroyCurrent(); else try { instance.destroy(); } catch { /* already gone */ } } };
}

export function destroyCurrent() {
  const i = current; current = null;
  if (i) try { i.destroy(); } catch { /* already gone */ }
}
