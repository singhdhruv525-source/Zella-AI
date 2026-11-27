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
    const root = document.querySelector(".zob-page") ?? document.body;
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    for (let n = walker.nextNode(); n; n = walker.nextNode()) {
      const el = n.parentElement, text = n.textContent.trim();
      // inert: the panels behind the frosted layer while confirming, deliberately out of reach and hidden from assistive tech
      if (!text || !el || el.closest(".ba-icon, .zob-sr, [hidden], [inert]")) continue;
      const cs = getComputedStyle(el);
      if (cs.visibility !== "visible" || Number(cs.opacity) === 0) continue;
      let op = 1; for (let a = el; a; a = a.parentElement) op *= Number(getComputedStyle(a).opacity);
      if (op < 0.5) continue;   // a layer on its way out (the card stepping back), not text to read
      const r = document.createRange(); r.selectNodeContents(n);
      const box = [...r.getClientRects()].filter((b) => b.width > 2 && b.height > 4 && b.bottom > 0 && b.top < innerHeight && b.left >= 0 && b.right <= innerWidth);
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
  await page.addScriptTag({ content: source }).catch(() => {});
  return page.evaluate(async () => {
    if (!window.axe) return ["axe did not load"];
    const r = await window.axe.run({ include: [".zob-page"] }, { runOnly: { type: "tag", values: ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa"] }, resultTypes: ["violations"] });
    return r.violations.filter((v) => v.impact === "serious" || v.impact === "critical").map((v) => `${v.id} (${v.nodes.length}): ${v.nodes[0]?.target.join(" ")}`);
  });
}

const overflow = (page) => page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth + 1);
const cardText = (page) => page.evaluate(() => [...document.querySelectorAll(".zgc-card")].filter((c) => getComputedStyle(c).opacity !== "0").map((c) => c.innerText).join(" | "));
const h1 = (page) => page.evaluate(() => document.querySelector("h1")?.textContent.trim());
const focused = (page) => page.evaluate(() => document.activeElement?.id || document.activeElement?.tagName);

const zellaOnCard = (page) => page.evaluate(() => [...document.querySelectorAll(".zgc-card")].some((c) => /Zella\s*Voice/i.test(c.textContent)));
const mockHasInputs = (page) => page.evaluate(() => document.querySelectorAll(".zgc-mock input, .zgc-mock textarea, .zgc-mock select, .zgc input, .zgc textarea, .zgc select").length);

module.exports = { LOOKS, WIDTHS, readPng, contrast, axeCard, overflow, cardText, h1, focused, zellaOnCard, mockHasInputs };
