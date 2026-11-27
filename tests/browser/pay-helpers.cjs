// Shared by the glass checkout browser tests (stripe-pay-screen.cjs, crm-payments.cjs): every Zella Voice look, the
// widths, AA contrast measured from rendered pixels (so glass, blur and pictures count), axe on the page card, and the
// small page probes. Local only.
const zlib = require("zlib");

const LOOKS = [
  { name: "zella", pref: null },
  { name: "classic", pref: { theme: "classic", background: "plain", dim: 35, matchPicture: false } },
  { name: "glass", pref: { theme: "glass", background: "plain", dim: 35, matchPicture: false } },
  { name: "glass-picture-match", pref: { theme: "glass", background: "lounge", dim: 35, matchPicture: true } },
  { name: "glass-picture-nomatch", pref: { theme: "glass", background: "aurora", dim: 35, matchPicture: false } },
];
const WIDTHS = [{ name: "1440", viewport: { width: 1440, height: 900 } }, { name: "390", viewport: { width: 390, height: 844 } }];

// ---- a minimal PNG reader (8 bit RGB or RGBA, not interlaced: what Chromium's screenshots are) ----
function readPng(buf) {
  let p = 8, width = 0, height = 0, channels = 4; const idat = [];
  while (p < buf.length) {
    const len = buf.readUInt32BE(p), type = buf.toString("ascii", p + 4, p + 8), data = buf.subarray(p + 8, p + 8 + len);
    if (type === "IHDR") { width = data.readUInt32BE(0); height = data.readUInt32BE(4); channels = data[9] === 6 ? 4 : 3; if (data[8] !== 8 || data[12] !== 0) throw new Error("unsupported png"); }
    if (type === "IDAT") idat.push(data);
    p += 12 + len;
  }
  const raw = zlib.inflateSync(Buffer.concat(idat)), stride = width * channels, out = Buffer.alloc(height * stride);
  for (let y = 0; y < height; y++) {
    const f = raw[y * (stride + 1)], row = raw.subarray(y * (stride + 1) + 1, (y + 1) * (stride + 1));
    for (let x = 0; x < stride; x++) {
      const a = x >= channels ? out[y * stride + x - channels] : 0, b = y ? out[(y - 1) * stride + x] : 0, c = x >= channels && y ? out[(y - 1) * stride + x - channels] : 0;
      const pr = a + b - c, pa = Math.abs(pr - a), pb = Math.abs(pr - b), pc = Math.abs(pr - c);
      const pred = [0, a, b, (a + b) >> 1, pa <= pb && pa <= pc ? a : pb <= pc ? b : c][f];
      out[y * stride + x] = (row[x] + pred) & 255;
    }
  }
  return { width, height, at: (x, y) => { const i = y * stride + x * channels; return [out[i], out[i + 1], out[i + 2]]; } };
}
const lum = ([r, g, b]) => { const f = (v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; }; return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b); };
const ratio = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((m, n) => n - m); return (x + 0.05) / (y + 0.05); };

// AA contrast for every visible text in the page card: the text's own colour against the pixels behind it, sampled
// from a screenshot with all text made transparent (so glass, blur and pictures behind are what is measured).
async function contrast(page) {
  const items = await page.evaluate(() => {
    const out = [];
    const pinnedRects = [...document.querySelectorAll("body *")].filter((e) => { const c = getComputedStyle(e); return (c.position === "fixed" || c.position === "sticky") && c.visibility === "visible" && c.display !== "none" && Number(c.opacity) > 0.05 && !e.closest(".zgc"); })
      .map((e) => ({ e, r: e.getBoundingClientRect() })).filter(({ r }) => r.width > 0 && r.height > 0);
    // a modal dialog open: only its text is read (the page behind it is dimmed on purpose and can't be reached)
    const dialog = [...document.querySelectorAll("[role=dialog][aria-modal=true]")].find((d) => ((r) => r.width > 0 && r.right > 0 && r.left < innerWidth && r.bottom > 0 && r.top < innerHeight)(d.getBoundingClientRect()) && getComputedStyle(d).visibility === "visible");
    const root = dialog ?? document.querySelector(".zob-page") ?? document.querySelector(".ba-content") ?? document.body;
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    for (let n = walker.nextNode(); n; n = walker.nextNode()) {
      const el = n.parentElement, text = n.textContent.trim();
      // inert: the panels behind the frosted layer while confirming, deliberately out of reach and hidden from assistive tech
      // disabled controls are exempt from contrast (WCAG 1.4.3, inactive user interface components)
      if (!text || !el || el.closest(".ba-icon, .zob-sr, [hidden], [inert], button:disabled, [aria-disabled='true']")) continue;
      const cs = getComputedStyle(el);
      if (cs.visibility !== "visible" || Number(cs.opacity) === 0) continue;
      let op = 1; for (let a = el; a; a = a.parentElement) op *= Number(getComputedStyle(a).opacity);
      if (op < 0.5) continue;   // a layer on its way out (the card stepping back), not text to read
      const r = document.createRange(); r.selectNodeContents(n);
      // a box under a fixed or sticky layer of the CRM shell (its top bar, the phone's tab bar) isn't what the person reads there
      const covered = (bx) => !dialog && pinnedRects.some(({ e, r: f }) => !e.contains(el) && f.left < bx.right && f.right > bx.left && f.top < bx.bottom && f.bottom > bx.top);
      const box = [...r.getClientRects()].filter((b) => b.width > 2 && b.height > 4 && b.bottom > 0 && b.top < innerHeight && b.left >= 0 && b.right <= innerWidth && !covered(b));
      if (!box.length) continue;
      const m = cs.color.match(/rgba?\(([^)]+)\)/)[1].split(/[ ,/]+/).filter(Boolean).map(Number);
      const size = parseFloat(cs.fontSize), bold = Number(cs.fontWeight) >= 700;
      out.push({ text: text.slice(0, 40), color: m, large: size >= 24 || (size >= 18.66 && bold), boxes: box.map((b) => [b.left, b.top, b.width, b.height]) });
    }
    return out;
  });
  await page.addStyleTag({ content: "*, *::before, *::after { color: transparent !important; text-shadow: none !important; caret-color: transparent !important; transition: none !important; } .zgc-card-shimmer { visibility: hidden !important; }", }).then((h) => h.evaluate((s) => { s.id = "zgc-test-hide"; }));
  await page.waitForTimeout(250);   // (the card's shimmer is a moving highlight that passes in a moment: hidden while measuring)
  const png = readPng(await page.screenshot());
  await page.evaluate(() => document.getElementById("zgc-test-hide")?.remove());
  const bad = [];
  for (const it of items) {
    const ratios = [];
    for (const [x0, y0, w, h] of it.boxes) {
      for (let i = 1; i < 6; i++) for (let j = 1; j < 4; j++) {
        const x = Math.min(png.width - 1, Math.round(x0 + (w * i) / 6)), y = Math.min(png.height - 1, Math.round(y0 + (h * j) / 4));
        const bg = png.at(x, y), a = it.color[3] ?? 1;
        const fg = [0, 1, 2].map((k) => Math.round(it.color[k] * a + bg[k] * (1 - a)));
        ratios.push(ratio(fg, bg));
      }
    }
    ratios.sort((m, n) => m - n);
    const worst = ratios[Math.floor(ratios.length * 0.1)];   // the 10th percentile: a stray border pixel isn't the background
    if (worst < (it.large ? 3 : 4.5)) bad.push(`"${it.text}" ${worst.toFixed(2)}:1`);
  }
  return { n: items.length, bad };
}

// axe on the page card (serious and critical only); text over translucent layers comes back "incomplete" there,
// which is why contrast() above measures it from pixels
async function axeCard(page, source) {
  await page.evaluate(source).catch(() => {});   // not a script element: the payment pages' enforcing CSP blocks inline scripts
  return page.evaluate(async () => {
    if (!window.axe) return ["axe did not load"];
    const where = document.querySelector(".zob-page") ? ".zob-page" : document.querySelector(".ba-content") ? ".ba-content" : "body";
    const r = await window.axe.run({ include: [where] }, { runOnly: { type: "tag", values: ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa"] }, resultTypes: ["violations"] });
    return r.violations.filter((v) => v.impact === "serious" || v.impact === "critical").map((v) => `${v.id} (${v.nodes.length}): ${v.nodes[0]?.target.join(" ")}`);
  });
}

const overflow = (page) => page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth + 1);
const cardText = (page) => page.evaluate(() => [...document.querySelectorAll(".zgc-card")].filter((c) => getComputedStyle(c).opacity !== "0").map((c) => c.innerText).join(" | "));
// the card may show only the last 4 and the expiry from Stripe's preview, never a longer run of digits
const onlyLast4AndExpiry = (t) => !/\d{5,}/.test(t) && (t.match(/\d+/g) ?? []).every((d) => ["4242", "12", "28"].includes(d));
const h1 = (page) => page.evaluate(() => document.querySelector("h1")?.textContent.trim());
const focused = (page) => page.evaluate(() => document.activeElement?.id || document.activeElement?.tagName);

const zellaOnCard = (page) => page.evaluate(() => [...document.querySelectorAll(".zgc-card")].some((c) => /Zella\s*Voice/i.test(c.textContent)));
// no input of ours at all: Stripe's card fields and its billing address fields are slots (Stripe's frames live, static
// text in the stand in), never inputs
// no field of ours in the checkout: the only inputs are the "I agree" box and the add on tick boxes (owner, 27 Nov 2026),
// never a card or address field (NN-9)
const mockHasInputs = (page) => page.evaluate(() => [...document.querySelectorAll(".zgc input, .zgc textarea, .zgc select")]
  .filter((e) => !(e.type === "checkbox" && (e.id === "zgc-consent" || e.closest(".zgc-addon")))).length);
// the "I agree" words as shown (the screen reader's "opens in a new tab" left out): exactly the words whose sha256 is sent
const consentWords = (page) => page.evaluate(() => { const l = document.querySelector(".zgc-consent label")?.cloneNode(true); l?.querySelectorAll(".zob-sr").forEach((n) => n.remove()); return l?.textContent ?? ""; });
// a press on Pay while the box is unticked: Pay is aria-disabled (still focusable and pressable, so it can say why)
const pressBlocked = (page, selector) => page.click(selector, { force: true });
// the required "I agree" box, then the first Pay button (it opens Stripe's form; the server records the agreement)
async function agree(page) { await page.check("#zgc-consent"); }
async function startPay(page, label = "Continue to pay") {
  await page.waitForSelector("#zgc-consent", { timeout: 10000 }).catch(() => {});
  await agree(page);
  await page.click(`.zgc-pay-foot button:has-text('${label}')`);
}
// the stand in's live fill: Stripe's test card played into the card slots, then the name into the billing address
async function fillCard(page) {
  await page.waitForSelector(".zgc-slot .zgc-slot-text", { timeout: 10000 }).catch(() => {});
  await page.click("button:has-text(\"Fill with Stripe's test card\")");
}
// the stand in's billing address: its country, its labels and values as drawn
const addressMock = (page) => page.evaluate(() => {
  const m = document.querySelector(".zgc-pay .zgc-addr-mock");
  if (!m) return null;
  return { country: m.dataset.country, labels: [...m.querySelectorAll(".zgc-addr-label")].map((l) => l.textContent),
    values: Object.fromEntries([...m.querySelectorAll(".zgc-addr-value")].map((v) => [v.dataset.part, v.classList.contains("is-placeholder") ? "" : v.textContent])) };
});
const waitFilled = (page) => page.waitForFunction(() => document.querySelector(".zgc-cardcol .zgc-card-front .zgc-cf-number")?.textContent.includes("4242"), null, { timeout: 15000 }).catch(() => {});

// the card's back once the turn has settled: the back face shown, and its magnetic stripe drawn dark (mean relative
// luminance of the stripe's middle band, from the rendered pixels)
async function backFace(page) {
  await page.waitForTimeout(900);   // the turn takes 760ms; the security code stays focused longer than that
  const info = await page.evaluate(() => {
    const card = document.querySelector(".zgc-cardcol .zgc-card");
    const back = card?.querySelector(".zgc-card-back"), stripe = back?.querySelector(".zgc-cb-stripe");
    if (!back || !stripe) return null;
    const r = stripe.getBoundingClientRect();
    return { isBack: card.classList.contains("is-back"), visible: getComputedStyle(back).visibility === "visible", rect: [r.x + window.scrollX, r.y + window.scrollY, r.width, r.height] };   // page coordinates
  });
  if (!info || info.rect[2] < 4 || info.rect[3] < 2) return { ...info, luminance: null };
  const [x, y, w, h] = info.rect;
  const png = readPng(await page.screenshot({ fullPage: true, clip: { x: x + w * 0.25, y: y + h * 0.3, width: Math.max(2, w * 0.5), height: Math.max(2, h * 0.4) } }));
  const lin = (c) => { c /= 255; return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4; };
  let sum = 0, n = 0;
  for (let i = 0; i < png.width; i++) for (let j = 0; j < png.height; j++) { const [r0, g0, b0] = png.at(i, j); sum += 0.2126 * lin(r0) + 0.7152 * lin(g0) + 0.0722 * lin(b0); n++; }
  return { ...info, luminance: sum / n };
}

// The payment pages' ENFORCING Content Security Policy, exactly as web/public/_headers sends it (owner decision, 27 Nov
// 2026), with the production Supabase host swapped for the local stand in's (the only difference). vite preview doesn't
// read _headers, so the tests add the header to those pages' documents themselves and count what the browser blocks.
const PAY_PAGE = /^\/(welcome\/setup|app\/settings\/billing\/(pay|pack)\/[^/]+)\/?$/;
function payPagePolicy() {
  const text = require("fs").readFileSync(require("path").join(__dirname, "../../web/public/_headers"), "utf8");
  const m = text.match(/^\/welcome\/setup\n {2}Content-Security-Policy: (.+)$/m);
  if (!m) throw new Error("no enforcing policy for /welcome/setup in _headers");
  return m[1].replace(/pffqxlumqhjdbzvvoszm\.supabase\.co/g, "zlocal.supabase.co");
}
// on a payment page's document: the enforcing header; anywhere: the browser's CSP violations counted
async function enforcePayPageCsp(ctx, route) {
  const u = new URL(route.request().url());
  if (route.request().isNavigationRequest() && PAY_PAGE.test(u.pathname)) {
    const resp = await route.fetch();
    ctx.__cspServed = (ctx.__cspServed ?? 0) + 1;
    return route.fulfill({ response: resp, headers: { ...resp.headers(), "content-security-policy": payPagePolicy() } });
  }
  return route.continue();
}
const watchCsp = (ctx) => ctx.addInitScript(() => { window.__cspViolations = []; document.addEventListener("securitypolicyviolation", (e) => window.__cspViolations.push(`${e.violatedDirective} ${e.blockedURI}`)); });
const cspViolations = (page) => page.evaluate(() => window.__cspViolations ?? []);

module.exports = { agree, startPay, consentWords, pressBlocked, enforcePayPageCsp, watchCsp, cspViolations, payPagePolicy, backFace, LOOKS, WIDTHS, readPng, contrast, axeCard, overflow, cardText, h1, focused, zellaOnCard, mockHasInputs, fillCard, waitFilled, onlyLast4AndExpiry, addressMock };
