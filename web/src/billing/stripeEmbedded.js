// Stripe.js and Stripe's card fields in our Payment details panel (owner, 27 Nov 2026), loaded only when needed: after
// the owner pressed Pay with payments live and our server returned a client secret. Never in the stand in path (the
// stand in apis bring their own mount).
//
// Loaded once, from https://js.stripe.com only, on the release that matches our pinned API version (2025-09-30.clover:
// js.stripe.com/clover/stripe.js; docs/PAYMENTS_ARCHITECTURE.md §16.10). Stripe requires it to be loaded directly from
// js.stripe.com, never bundled or hosted by us (the @stripe/stripe-js README, "to be PCI compliant"), and serves updates
// at that same address, so a fixed Subresource Integrity hash would break it: no SRI. The CSP allows js.stripe.com.
//
// The card is typed only into Stripe's three fields (card number, expiry, security code), each in Stripe's own frame,
// which this page can't read (NN-9). What the page learns comes only from Stripe:
//   - while typing: each field's change event (the card number's brand, empty, complete) and focus and blur;
//   - once all three are complete: stripe.createPaymentMethod (no charge) returns the card's brand, last 4 and expiry
//     month and year. These are not the card number. They live only in the checkout's view state, in memory.
// The billing address is Stripe's Address Element (mode billing: autocomplete and each country's own format), under
// the card fields: the cardholder's full name and the address, any country (no allowedCountries; owner, 27 Nov 2026),
// the United States first. It is prefilled from the business's own address, which the owner can change. Its value goes
// to Stripe as the PaymentMethod's billing_details { name, address }; we keep it only in memory and never log or save it.
// The name is mirrored on the card illustration; the address never is.
// On Pay that same PaymentMethod confirms the payment: a Checkout Session (ui_mode custom, the onboarding Pay step)
// through checkout.loadActions().confirm({ paymentMethod }), or a PaymentIntent (Pay now, finishing a pack) through
// stripe.confirmCardPayment(clientSecret, { payment_method }). Either way OUR server confirms afterwards.
// The client secret stays in memory: never in the address bar, storage, logs or error reports.

export const STRIPE_JS_URL = "https://js.stripe.com/clover/stripe.js";
const LOAD_TIMEOUT_MS = 15000;
let loading = null;
let current = null;   // the one card form on the page

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

// The card fields' look from the current look's tokens (Stripe's card elements take a style object, not CSS).
export function fieldStyle(root = globalThis.document?.documentElement) {
  const css = root ? getComputedStyle(root) : null;
  const v = (name, fallback) => (css?.getPropertyValue(name).trim() || fallback);
  return {
    base: { color: v("--zella-text", "#0B0F1A"), fontFamily: "Inter, system-ui, sans-serif", fontSize: "16px", fontSmoothing: "antialiased",
      iconColor: v("--zella-primary", "#0B0F1A"), "::placeholder": { color: v("--zella-text-secondary", "#5B6170") } },
    invalid: { color: v("--zella-danger", "#B42318"), iconColor: v("--zella-danger", "#B42318") },
  };
}

// The Address Element follows the look through Stripe's Appearance API (variables from the same tokens).
export function fieldAppearance(root = globalThis.document?.documentElement) {
  const css = root ? getComputedStyle(root) : null;
  const v = (name, fallback) => (css?.getPropertyValue(name).trim() || fallback);
  return { theme: "stripe", variables: { colorPrimary: v("--zella-primary", "#0B0F1A"), colorBackground: v("--zella-card", "#FFFFFF"),
    colorText: v("--zella-text", "#0B0F1A"), colorTextSecondary: v("--zella-text-secondary", "#5B6170"), colorDanger: v("--zella-danger", "#B42318"),
    fontFamily: "Inter, system-ui, sans-serif", fontSizeBase: "16px", borderRadius: "10px" } };
}

// The card from Stripe's PaymentMethod preview: brand, last 4, expiry. Nothing else is read.
export function previewOf(pm) {
  const c = pm?.card ?? {};
  const last4 = /^\d{4}$/.test(String(c.last4 ?? "")) ? String(c.last4) : null;
  const m = Number(c.exp_month), y = Number(c.exp_year);
  return { brand: typeof c.brand === "string" ? c.brand : null, last4,
    exp: Number.isInteger(m) && m >= 1 && m <= 12 && Number.isInteger(y) && y > 2000 ? `${String(m).padStart(2, "0")}/${String(y % 100).padStart(2, "0")}` : null };
}

// Mounts Stripe's card number, expiry and security code fields into our three slots.
//   kind "checkout": clientSecret is a Checkout Session's (ui_mode custom); kind "intent": a PaymentIntent's.
//   onEvent({ type: "change" | "focus" | "blur", field, brand?, empty?, complete? }) and onEvent({ type: "preview", card })
//   onEvent({ type: "address", name, complete }) as the billing address changes (the name only, for the card)
//   prefill: the business's address ({ line1, line2, city, state, postal_code, country }), every part optional
// Returns { destroy, submit }. submit() confirms with the PaymentMethod; onComplete then only starts "confirming".
export function addressOptions(prefill) {
  const p = prefill && typeof prefill === "object" ? prefill : {};
  const address = { country: /^[A-Z]{2}$/.test(String(p.country ?? "")) ? p.country : "US" };
  for (const k of ["line1", "line2", "city", "state", "postal_code"]) if (typeof p[k] === "string" && p[k]) address[k] = p[k].slice(0, 100);
  // no allowedCountries: a card and an address from any country (owner, 27 Nov 2026)
  return { mode: "billing", display: { name: "full" }, autocomplete: { mode: "automatic" }, defaultValues: { name: "", address } };
}

export async function mountCardFields(slots, { kind, clientSecret, publishableKey, livemode, onEvent, onComplete, prefill, returnUrl }) {
  checkKeyMode(publishableKey, livemode);
  const Stripe = await loadStripeJs();
  destroyCurrent();
  let stripe, checkout = null, elements, fields;
  try {
    stripe = Stripe(publishableKey);
    if (kind === "checkout") checkout = await stripe.initCheckout({ clientSecret });
    elements = stripe.elements({ appearance: fieldAppearance() });
    const style = fieldStyle();
    fields = {
      number: elements.create("cardNumber", { style, showIcon: true, placeholder: "1234 1234 1234 1234" }),
      expiry: elements.create("cardExpiry", { style }),
      cvc: elements.create("cardCvc", { style }),
    };
    if (slots.address) fields.address = elements.create("address", addressOptions(prefill));
  } catch {
    throw fail("STRIPE_JS", "Stripe's form couldn't start");   // never pass Stripe's own error text on: it can carry ids
  }
  const done = { number: false, expiry: false, cvc: false, address: !fields.address };
  let pm = null, pmFor = null, seq = 0;
  let billing = { name: "", address: null };   // the Address Element's latest value, memory only
  const billingKey = () => JSON.stringify(billing);
  async function makePaymentMethod() {
    const key = billingKey(), n = billing.name.trim().slice(0, 80);
    const details = { ...(n ? { name: n } : {}), ...(billing.address ? { address: billing.address } : {}) };
    const r = await stripe.createPaymentMethod({ type: "card", card: fields.number, ...(Object.keys(details).length ? { billing_details: details } : {}) });
    if (r.error) throw fail("DECLINED", typeof r.error.message === "string" ? r.error.message : "Check the card details.");
    pm = r.paymentMethod; pmFor = key;
    return pm;
  }
  async function maybePreview() {
    if (!(done.number && done.expiry && done.cvc)) return;
    const mine = ++seq;
    try { const p = await makePaymentMethod(); if (mine === seq) onEvent?.({ type: "preview", card: previewOf(p) }); }
    catch { /* the field shows Stripe's own message; nothing is guessed */ }
  }
  for (const [field, el] of Object.entries(fields)) {
    el.mount(slots[field]);
    if (field === "address") {
      el.on("change", (e) => {
        const v = e.value ?? {};
        const a = v.address ?? {};
        billing = { name: typeof v.name === "string" ? v.name : "",
          address: { line1: a.line1 || null, line2: a.line2 || null, city: a.city || null, state: a.state || null, postal_code: a.postal_code || null, country: a.country || null } };
        done.address = e.complete === true;
        onEvent?.({ type: "address", name: billing.name.trim().slice(0, 80), complete: done.address });
      });
      continue;
    }
    el.on("change", (e) => {
      done[field] = e.complete === true;
      onEvent?.({ type: "change", field, empty: e.empty === true, complete: e.complete === true, ...(field === "number" ? { brand: typeof e.brand === "string" ? e.brand : null } : {}) });
      // Stripe sends change only when the field's value changed: whatever was previewed no longer matches (a new digit
      // in a complete number stays complete), so the cached PaymentMethod is dropped, a preview on its way is ignored,
      // and a new one is made when all three are complete (review). With no change the cached one is reused at Pay.
      pm = null; seq++;
      if (done.number && done.expiry && done.cvc) maybePreview(); else onEvent?.({ type: "preview", card: null });
    });
    el.on("focus", () => onEvent?.({ type: "focus", field }));
    el.on("blur", () => onEvent?.({ type: "blur", field }));
  }
  const instance = { destroy: () => Object.values(fields).forEach((f) => { try { f.destroy(); } catch { /* gone */ } }) };
  current = instance;
  return {
    destroy: () => { if (current === instance) destroyCurrent(); else instance.destroy(); },
    submit: async () => {
      if (!(done.number && done.expiry && done.cvc)) throw fail("DECLINED", "Complete the card details first.");
      if (!done.address) throw fail("DECLINED", "Complete the billing address first.");
      // the same PaymentMethod as the preview, or a new one when the billing address changed since
      const method = pm && pmFor === billingKey() ? pm : await makePaymentMethod();
      if (checkout) {
        const a = await checkout.loadActions();
        if (a.type !== "success") throw fail("DECLINED", "Stripe's form isn't ready. Please try again.");
        const addr = Object.fromEntries(Object.entries(billing.address ?? {}).filter(([, v]) => v));
        const r = await a.actions.confirm({ paymentMethod: method.id, redirect: "if_required", returnUrl,
          ...(billing.address ? { billingAddress: { name: billing.name.trim().slice(0, 80), address: addr } } : {}) });
        if (r.type !== "success") throw fail("DECLINED", typeof r.error?.message === "string" ? r.error.message : "The payment didn't go through. Nothing was charged.");
        onComplete?.();
        return;
      }
      const r = await stripe.confirmCardPayment(clientSecret, { payment_method: method.id });
      if (r.error) throw fail("DECLINED", typeof r.error.message === "string" ? r.error.message : "The payment didn't go through. Nothing was charged.");
      if (["succeeded", "processing", "requires_capture"].includes(r.paymentIntent?.status)) onComplete?.();
      else throw fail("DECLINED", "The payment didn't go through. Nothing was charged.");
    },
  };
}

export function destroyCurrent() {
  const i = current; current = null;
  if (i) try { i.destroy(); } catch { /* already gone */ }
}
