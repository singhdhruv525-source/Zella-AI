// The local preview's stand in for Stripe's card fields (stand in apis only: onboarding/fakeApi.js and
// billing/fakeBillingApi.js, both loaded only in a build made with VITE_ONBOARDING_FAKE=1, never in a live build's flow,
// which mounts Stripe's real fields). Same interface as stripeEmbedded.js mountCardFields: it draws static text in our
// three slots (no input, select or textarea of any kind) and, on demo(), plays the events Stripe's fields would send
// while someone types Stripe's public test card (4242 4242 4242 4242, 12/28, 123): the brand as soon as it is known,
// empty and complete, focus and blur, then the PaymentMethod preview (brand, last 4, expiry). Fake data only.
// Under the card fields: a static mock of Stripe's billing address fields (Address Element, mode billing), drawn as
// text in the address slot, laid out in the country's own format (the United States: State and ZIP code; Canada:
// Province and Postal code; elsewhere: Region and Postal code), prefilled from the stand in's business address.
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

const COUNTRIES = { US: "United States", CA: "Canada", GB: "United Kingdom", AU: "Australia" };
// the labels each country's address uses, as Stripe's fields show them (stand in only)
export function addressFormat(country) {
  if (country === "US") return { state: "State", postal: "ZIP code" };
  if (country === "CA") return { state: "Province", postal: "Postal code" };
  if (country === "GB") return { state: null, postal: "Postcode", city: "Town or city" };
  return { state: "State or region", postal: "Postal code" };
}

function drawAddress(slot, prefill) {
  const doc = slot.ownerDocument;
  const country = /^[A-Z]{2}$/.test(String(prefill?.country ?? "")) ? prefill.country : "US";
  const f = addressFormat(country);
  const rows = [
    [["name", "Full name", ""]],
    [["country", "Country or region", COUNTRIES[country] ?? country]],
    [["line1", "Address line 1", prefill?.line1 ?? ""]],
    [["line2", "Address line 2 (optional)", prefill?.line2 ?? ""]],
    [["city", f.city ?? "City", prefill?.city ?? ""]],
    f.state ? [["state", f.state, prefill?.state ?? ""], ["postal_code", f.postal, prefill?.postal_code ?? ""]] : [["postal_code", f.postal, prefill?.postal_code ?? ""]],
  ];
  const wrap = doc.createElement("div");
  wrap.className = "zgc-addr-mock";
  wrap.dataset.country = country;
  wrap.setAttribute("aria-hidden", "true");
  const values = {};
  for (const row of rows) {
    const line = doc.createElement("div");
    line.className = "zgc-addr-row";
    for (const [key, label, value] of row) {
      const cell = doc.createElement("div");
      cell.className = "zgc-addr-cell";
      const l = doc.createElement("span");
      l.className = "zgc-addr-label";
      l.textContent = label;
      const v = doc.createElement("span");
      v.className = `zgc-input zgc-slot-text zgc-addr-value${value ? "" : " is-placeholder"}`;
      v.dataset.part = key;
      v.textContent = value || label.replace(" (optional)", "");
      cell.append(l, v);
      line.append(cell);
      values[key] = v;
    }
    wrap.append(line);
  }
  slot.replaceChildren(wrap);
  return { country, values };
}

// The bank's own check (3D Secure), as a clearly labelled PREVIEW: live, Stripe.js opens the bank's real page (a code or
// an app approval) in Stripe's overlay and we never draw it. Approve, Fail or Close: resolves "approve" | "fail" | "cancel".
// A modal dialog (review round 3): Tab and Shift+Tab stay inside it, and focus goes back to where it was whenever it
// closes (a button, Escape, or the form being taken down, which settles the wait as "cancel").
function bankPreview(doc) {
  let settle = () => {};
  const promise = new Promise((resolve) => {
    const before = doc.activeElement ?? null;
    const shade = doc.createElement("div");
    shade.className = "zgc-bank-preview";
    const box = doc.createElement("div");
    box.className = "zgc-bank-preview-box";
    box.setAttribute("role", "dialog"); box.setAttribute("aria-modal", "true"); box.setAttribute("aria-labelledby", "zgc-bank-preview-t");
    const badge = doc.createElement("span"); badge.className = "zgc-mock-badge"; badge.textContent = "Preview only";
    const h = doc.createElement("h2"); h.id = "zgc-bank-preview-t"; h.textContent = "Preview of your bank's verification";
    const p = doc.createElement("p"); p.textContent = "Live, your bank shows its own check here, in Stripe's secure window: a code by text or an approval in your banking app. Zella Voice never sees it.";
    const row = doc.createElement("div"); row.className = "zgc-bank-preview-actions";
    let open = true;
    settle = (value) => {
      if (!open) return;
      open = false;
      shade.remove();
      try { if (before && typeof before.focus === "function" && before.isConnected !== false) before.focus(); } catch { /* gone */ }
      resolve(value);
    };
    const btn = (label, cls, value) => { const b = doc.createElement("button"); b.type = "button"; b.className = `ba-btn ${cls}`; b.textContent = label; b.addEventListener("click", () => settle(value)); return b; };
    const buttons = [btn("Approve", "primary", "approve"), btn("Fail", "", "fail"), btn("Close", "", "cancel")];
    row.append(...buttons);
    box.append(badge, h, p, row); shade.append(box); doc.body.append(shade);
    shade.addEventListener("keydown", (e) => {
      if (e.key === "Escape") { e.preventDefault?.(); settle("cancel"); return; }
      if (e.key !== "Tab") return;
      const at = buttons.indexOf(doc.activeElement);
      const to = e.shiftKey ? (at <= 0 ? buttons.length - 1 : at - 1) : (at === -1 || at === buttons.length - 1 ? 0 : at + 1);
      e.preventDefault?.();
      buttons[to].focus();
    });
    buttons[0].focus();
  });
  return { promise, close: () => settle("cancel") };
}

// outcomes: what each Pay does, in order (stand in scenarios), the last one repeating: "ok", "verify" (the bank's
// check, then approve or fail), "declined:<Stripe decline code>", "unknown" (no answer from Stripe)
export function mountStandInCard(slots, { onEvent, onComplete, prefill }, { onPay, speed = 45, holderName = "Jordan Lee", outcomes = ["ok"] } = {}) {
  const doc = slots.number.ownerDocument;
  const address = slots.address ? drawAddress(slots.address, prefill) : null;
  const addressFilled = () => Boolean(address) && ["line1", "city", "postal_code"].every((k) => !address.values[k].classList.contains("is-placeholder"))
    && (!address.values.state || !address.values.state.classList.contains("is-placeholder"));
  const boxes = {};
  for (const [field, text] of [["number", "1234 1234 1234 1234"], ["expiry", "MM / YY"], ["cvc", "CVC"]]) {
    const span = doc.createElement("span");
    span.className = "zgc-slot-text is-placeholder";
    span.setAttribute("aria-hidden", "true");
    span.textContent = text;
    slots[field].replaceChildren(span);
    boxes[field] = span;
  }
  const done = { number: false, expiry: false, cvc: false, address: !address };
  let alive = true, preview = null, bank = null;   // bank: the bank preview while it is open
  // the billing address mock: the name typed letter by letter (mirrored on the card), the rest as prefilled
  const typeName = async () => {
    if (!address) return;
    const box = address.values.name;
    let text = "";
    for (let i = 0; i < holderName.length && alive; i++) {
      text += holderName[i];
      box.textContent = text;
      box.classList.remove("is-placeholder");
      onEvent?.({ type: "address", name: text, complete: false });
      await wait(speed);
    }
    if (!alive) return;
    if (!addressFilled()) {   // no business address on file: the stand in's own fake address
      const fake = address.country === "CA" ? { line1: "100 King St W", city: "Toronto", state: "ON", postal_code: "M5H 3T4" }
        : { line1: "1 Example Way", city: "Austin", state: "TX", postal_code: "78701" };
      for (const [k, v] of Object.entries(fake)) if (address.values[k]?.classList.contains("is-placeholder")) { address.values[k].textContent = v; address.values[k].classList.remove("is-placeholder"); }
    }
    done.address = true;
    onEvent?.({ type: "address", name: text, complete: true });
  };
  const plan = [...outcomes];
  const next = () => (plan.length > 1 ? plan.shift() : plan[0] ?? "ok");
  const failWith = (code, extra = {}) => Object.assign(new Error(extra.message ?? "The payment didn't go through."), { code, ...extra });
  // a field Stripe reports invalid: its words under the field, not complete, no preview (Pay stays disabled)
  const wrong = async (field, chars, error) => {
    onEvent?.({ type: "focus", field });
    boxes[field].textContent = chars; boxes[field].classList.remove("is-placeholder");
    done[field] = false;
    onEvent?.({ type: "change", field, empty: false, complete: false, error, ...(field === "number" ? { brand: "visa" } : {}) });
    await wait(speed * 4);
    onEvent?.({ type: "blur", field });
  };
  const type = async (field, chars, { brandAt, hold = 4 } = {}) => {
    onEvent?.({ type: "focus", field });
    let text = "";
    for (let i = 0; i < chars.length && alive; i++) {
      text += chars[i];
      boxes[field].textContent = text;
      boxes[field].classList.remove("is-placeholder");
      const complete = i === chars.length - 1;
      done[field] = complete;
      onEvent?.({ type: "change", field, empty: false, complete, error: null, ...(field === "number" ? { brand: i >= (brandAt ?? 0) ? "visa" : "unknown" } : {}) });
      await wait(speed);
    }
    await wait(speed * hold);
    onEvent?.({ type: "blur", field });
  };
  return {
    // taken down: an open bank preview closes and its wait settles; nothing is paid after this (review round 3)
    destroy: () => { alive = false; bank?.close(); bank = null; Object.values(slots).forEach((s) => s.replaceChildren()); },
    // plays the test card being typed, field by field (the CVC turns the card over), then Stripe's preview
    demo: async () => {
      await type("number", "4242 4242 4242 4242", { brandAt: 0 });
      await type("expiry", "12 / 28");
      await type("cvc", "123", { hold: 60 });   // a moment on the security code, with the card turned over
      await typeName();
      if (!alive) return;
      preview = { brand: "visa", last4: "4242", exp: "12/28" };
      onEvent?.({ type: "preview", card: preview });
    },
    // wrong card details, as Stripe's fields report them inline (stand in: Stripe's wording style): an invalid number,
    // a date in the past, an incomplete security code, an incomplete ZIP code; no preview, so no last 4
    demoInvalid: async () => {
      preview = null; onEvent?.({ type: "preview", card: null });
      await wrong("number", "4242 4242 4242 4241", "Your card number is invalid.");
      await wrong("expiry", "12 / 20", "Your card's expiration year is in the past.");
      await wrong("cvc", "12", "Your card's security code is incomplete.");
      if (address?.values.postal_code) {
        address.values.postal_code.textContent = "1234"; address.values.postal_code.classList.remove("is-placeholder");
        done.address = false;
        onEvent?.({ type: "address", name: address.values.name.textContent === "Full name" ? "" : address.values.name.textContent, complete: false, error: address.country === "US" ? "Your ZIP code is incomplete." : "Your postal code is invalid." });
      }
    },
    // "Try another card": the fields emptied, the same payment kept
    clear: () => {
      preview = null;
      for (const [field, text] of [["number", "1234 1234 1234 1234"], ["expiry", "MM / YY"], ["cvc", "CVC"]]) { boxes[field].textContent = text; boxes[field].classList.add("is-placeholder"); done[field] = false;
        onEvent?.({ type: "change", field, empty: true, complete: false, error: null }); }
      onEvent?.({ type: "preview", card: null });
    },
    submit: async () => {
      if (!(done.number && done.expiry && done.cvc) || !preview) throw Object.assign(new Error("Complete the card details first."), { code: "LOCAL_CHECK" });
      if (!done.address) throw Object.assign(new Error("Complete the billing address first."), { code: "LOCAL_CHECK" });
      const w = doc.defaultView; if (w) w.__zgcConfirms = (w.__zgcConfirms ?? 0) + 1;   // the browser tests count confirms
      const outcome = next();
      await wait(speed * 4);
      if (outcome.startsWith("declined:")) throw failWith("DECLINED", { decline_code: outcome.slice(9), stripe_type: "card_error", stripe_code: "card_declined" });
      if (outcome === "unknown") throw failWith("UNKNOWN_OUTCOME");
      const gone = () => failWith("LOCAL_CHECK", { message: "The card form was closed." });
      if (!alive) throw gone();
      if (outcome === "verify") {
        onEvent?.({ type: "bank", waiting: true });
        bank = bankPreview(doc);
        const answer = await bank.promise;
        bank = null;
        if (!alive) throw gone();
        onEvent?.({ type: "bank", waiting: false });
        if (answer !== "approve") throw failWith("BANK_FAILED", { stripe_code: "payment_intent_authentication_failure" });
      }
      await onPay?.();
      if (!alive) return;
      onComplete?.();
    },
  };
}
