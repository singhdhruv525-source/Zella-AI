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

export function mountStandInCard(slots, { onEvent, onComplete, prefill }, { onPay, speed = 45, holderName = "Jordan Lee" } = {}) {
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
  let alive = true, preview = null;
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
  const type = async (field, chars, { brandAt, hold = 4 } = {}) => {
    onEvent?.({ type: "focus", field });
    let text = "";
    for (let i = 0; i < chars.length && alive; i++) {
      text += chars[i];
      boxes[field].textContent = text;
      boxes[field].classList.remove("is-placeholder");
      const complete = i === chars.length - 1;
      done[field] = complete;
      onEvent?.({ type: "change", field, empty: false, complete, ...(field === "number" ? { brand: i >= (brandAt ?? 0) ? "visa" : "unknown" } : {}) });
      await wait(speed);
    }
    await wait(speed * hold);
    onEvent?.({ type: "blur", field });
  };
  return {
    destroy: () => { alive = false; Object.values(slots).forEach((s) => s.replaceChildren()); },
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
    submit: async () => {
      if (!(done.number && done.expiry && done.cvc) || !preview) throw Object.assign(new Error("Complete the card details first."), { code: "DECLINED" });
      if (!done.address) throw Object.assign(new Error("Complete the billing address first."), { code: "DECLINED" });
      await onPay?.();
      onComplete?.();
    },
  };
}
