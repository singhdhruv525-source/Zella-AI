// The local preview's stand in for Stripe's form (stand in apis only: onboarding/fakeApi.js and billing/fakeBillingApi.js,
// both loaded only in a build made with VITE_ONBOARDING_FAKE=1, never in a live build's flow, which mounts Stripe's
// real iframe). A static picture of Stripe's fields so the preview shows where the card goes: divs with aria-hidden,
// no input, select or textarea of any kind, clearly badged, with one visually hidden note for screen readers.
//   withButton: Embedded Checkout has its own Pay button inside Stripe's frame, so the stand in draws one too; the
//   Payment Element has none (our Pay button under it confirms).
export function renderStandInForm(el, { amountLabel = "", withButton = false, onPay } = {}) {
  const doc = el.ownerDocument;
  const make = (tag, cls, text) => { const n = doc.createElement(tag); if (cls) n.className = cls; if (text != null) n.textContent = text; return n; };
  const box = make("div", ["zgc-mock", "zgc-standin"].join(" "));
  const badge = make("span", "zgc-mock-badge", "Preview of Stripe's form");
  const note = make("p", "zob-sr", "Preview only. On the live site, Stripe's own secure card form appears here, inside Stripe's frame. This local preview never loads Stripe and takes no card.");
  const fields = make("div", "zgc-mock-fields");
  fields.setAttribute("aria-hidden", "true");
  const field = (label, placeholder, wide, extra) => {
    const f = make("div", `zgc-mock-field${wide ? " wide" : ""}`);
    const b = make("div", "zgc-mock-box");
    b.append(make("span", "", placeholder));
    if (extra) b.append(extra);
    f.append(make("div", "zgc-mock-label", label), b);
    return f;
  };
  const brands = make("span", "zgc-mock-brands"); brands.append(make("i"), make("i"), make("i"));
  fields.append(
    field("Cardholder name", "Full name on card", true),
    field("Card number", "1234 1234 1234 1234", true, brands),
    field("Expiration", "MM / YY", false),
    field("Security code", "CVC", false),
    field("Country", "United States", true),
  );
  const save = make("div", "zgc-mock-save");
  save.append(make("span", "zgc-mock-check"), make("span", "", "Save card for next time"));
  fields.append(save);
  box.append(badge, note, fields);
  if (withButton) {
    const btn = make("button", ["ba-btn", "primary", "zgc-pay-btn"].join(" "), amountLabel ? `Pay ${amountLabel}` : "Pay");
    btn.type = "button";
    btn.addEventListener("click", () => onPay?.());
    box.append(btn);
  }
  el.replaceChildren(box);
  return box;
}
