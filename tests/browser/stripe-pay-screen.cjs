// The owner onboarding Pay screen as a glass checkout (owner, 27 Nov 2026), in a real browser, against the stand in api
// (web/src/onboarding/fakeApi.js). The stand in brings its own stand in for Stripe's embedded form, so Stripe.js is
// never loaded and nothing reaches Supabase or Stripe: every request off this machine is refused here and counted.
//
// Every state, in every Zella Voice look, at 1440x900 and 390 wide (and 320 for the layout):
//   ready ...... Ready to pay, the summary with the server's amount, Pay securely
//   form ....... the embedded form's area with the stand in mounted
//   processing . after the form completes: the panels soften, the card moves to the centre, "Confirming your payment"
//   confirmed .. only after the server confirms: the card turns the look's success colour, brand and last 4 only
//   off ........ payments not switched on: "Payment opens here soon" and Continue
// Looks: Zella Voice (default), Classic, Glass plain, Glass over a picture with "Match colours to the picture" on and off.
// Each shot also checks: no horizontal scroll; AA contrast of every visible text in the page card, measured from the
// rendered pixels behind it (so translucent glass and pictures count); no card field of ours and no digits on the card
// before a verified payment. Reduced motion is checked in each look: no blur and no flight, just the states.
//
// Build and serve a LOCAL copy (never a production build):
//   cd web && VITE_ONBOARDING_FAKE=1 VITE_SUPABASE_URL=https://zlocal.supabase.co \
//     VITE_SUPABASE_PUBLISHABLE_KEY=sb_publishable_local_test_only npx vite build --outDir /tmp/zella-pay
//   npx vite preview --outDir /tmp/zella-pay --port 5150 --strictPort
// Then: APP_URL=http://localhost:5150 SHOTS=<folder> node tests/browser/stripe-pay-screen.cjs   (axe: npm ci --prefix tests/browser)
const { chromium } = require("playwright");
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");
const { loadAxe } = require("./axe.cjs");
const APP = process.env.APP_URL ?? "http://localhost:5150";
const SHOTS = process.env.SHOTS ?? path.join(process.cwd(), "pay-shots");
if (!["localhost", "127.0.0.1"].includes(new URL(APP).hostname)) { console.error("APP_URL must be a local preview"); process.exit(2); }
fs.mkdirSync(SHOTS, { recursive: true });
let fails = 0, passes = 0;
const check = (name, ok, detail = "") => { console.log(`${ok ? "PASS" : "FAIL"} ${name}${detail ? " - " + detail : ""}`); if (ok) passes++; else fails++; };

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

async function seed(scenario) {
  const { createFakeApi } = await import(path.join(__dirname, "../../web/src/onboarding/fakeApi.js"));
  const mem = new Map(); const storage = { getItem: (k) => mem.get(k) ?? null, setItem: (k, v) => mem.set(k, v) };
  const api = createFakeApi({ scenario, storage, delay: 0 });
  const id = (await api.listBusinesses()).businesses[0].business_id;
  await api.completeStep(id, "welcome"); await api.setPassword("A good pass 1!"); await api.finishMfa("x", "123456"); await api.completeStep(id, "security");
  const shown = await api.getState(id);
  for (const k of ["business", "hours_services", "team", "receptionist_phone"]) await api.answerSection(id, k, "looks_right", null, shown.details.sections.find((x) => x.key === k).data_hash);
  await api.completeStep(id, "details"); api.approveIdentity(); await api.completeStep(id, "identity");
  const s = await api.getState(id); await api.acceptPlan(id, s.plan.current.version);
  return [...mem.entries()];
}

async function open(browser, { look, viewport, seeded, scenario, reduced = false, query = "", video = null }) {
  const ctx = await browser.newContext({ viewport, deviceScaleFactor: 1, reducedMotion: reduced ? "reduce" : "no-preference", ...(video ? { recordVideo: { dir: video, size: viewport } } : {}) });
  const hits = [];
  await ctx.route((url) => ["http:", "https:"].includes(url.protocol), async (route) => {
    const url = new URL(route.request().url());
    if (["localhost", "127.0.0.1", "fonts.googleapis.com", "fonts.gstatic.com"].includes(url.hostname)) return route.continue();
    hits.push(`${route.request().method()} ${url.hostname}${url.pathname}`);
    return route.fulfill({ status: 503, contentType: "application/json", body: "{}" });
  });
  await ctx.addInitScript(([entries, pref]) => {
    if (!sessionStorage.getItem("seeded")) {
      for (const [k, v] of entries) localStorage.setItem(k, v);
      if (pref) localStorage.setItem("zella.appearance.crm", JSON.stringify({ user: null, pref }));
      sessionStorage.setItem("seeded", "1");
    }
  }, [seeded, look.pref]);
  const page = await ctx.newPage();
  const errors = []; page.on("pageerror", (e) => errors.push(e.message));
  await page.goto(`${APP}/welcome/setup?scenario=${scenario}${query}`);
  await page.waitForSelector(".zgc", { timeout: 15000 }).catch(() => {});
  await page.waitForTimeout(400);   // fonts and, in Glass over a picture, the palette taken from it
  return { ctx, page, hits, errors };
}

const overflow = (page) => page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth + 1);
const cardText = (page) => page.evaluate(() => [...document.querySelectorAll(".zgc-card")].filter((c) => getComputedStyle(c).opacity !== "0").map((c) => c.innerText).join(" | "));
const h1 = (page) => page.evaluate(() => document.querySelector("h1")?.textContent.trim());
const focused = (page) => page.evaluate(() => document.activeElement?.id || document.activeElement?.tagName);

async function shot(page, look, width, state, axeSource) {
  const file = path.join(SHOTS, `pay-${look.name}-${state}-${width.name}.png`);
  await page.screenshot({ path: file, fullPage: true });
  const tag = `${look.name} ${width.name} ${state}`;
  check(`${tag}: no horizontal scroll`, !(await overflow(page)));
  const c = await contrast(page);
  check(`${tag}: AA contrast for all ${c.n} texts`, c.n > 0 && c.bad.length === 0, c.bad.slice(0, 4).join("; "));
  const ax = await axeCard(page, axeSource);
  check(`${tag}: axe finds no serious problem in the page card`, ax.length === 0, ax.slice(0, 3).join("; "));
  check(`${tag}: no card field of ours (the card is typed only into Stripe's frame)`, (await page.locator(".zgc input, .zgc select, .zgc textarea").count()) === 0);
}

(async () => {
  const axeSource = loadAxe();
  const seededPay = await seed("pay");
  const seededOff = await seed("");
  const browser = await chromium.launch();
  for (const look of LOOKS) {
    for (const width of WIDTHS) {
      // ready, form, processing, confirmed: one walk through
      const { ctx, page, hits, errors } = await open(browser, { look, viewport: width.viewport, seeded: seededPay, scenario: "pay" });
      const tag = `${look.name} ${width.name}`;
      await page.waitForSelector("text=Ready to pay", { timeout: 10000 }).catch(() => {});
      check(`${tag}: ready, with the server's amount`, await page.isVisible("text=Ready to pay") && (await page.locator(".zgc-total strong").innerText()) === "$898");
      check(`${tag}: Back and Finish later are there`, await page.isVisible("button:has-text('Back')") && await page.isVisible("button:has-text('Finish later')"));
      check(`${tag}: the card has no digits before payment, only placeholder dots`, !/\d/.test(await cardText(page)) && (await cardText(page)).includes("••••"));
      check(`${tag}: the trust row and an icon on each summary line`, (await page.locator(".zgc-trust").innerText()).includes("Card details never reach Zella Voice")
        && (await page.locator(".zgc-lines > div").count()) === (await page.locator(".zgc-lines .zgc-line-icon").count()));
      await shot(page, look, width, "ready", axeSource);

      await page.click("button:has-text('Pay securely')");
      await page.waitForSelector(".zgc-standin", { timeout: 10000 }).catch(() => {});
      check(`${tag}: the embedded form's area shows (stand in)`, await page.isVisible(".zgc-standin"));
      check(`${tag}: Stripe.js is never loaded by the stand in`, await page.evaluate(() => ![...document.scripts].some((s) => s.src.includes("stripe.com"))));
      await shot(page, look, width, "form", axeSource);

      await page.click("button:has-text('Complete the stand in payment')");
      await page.waitForFunction(() => document.querySelector("h1")?.textContent.includes("Confirming your payment"), null, { timeout: 8000 }).catch(() => {});
      await page.waitForTimeout(150);
      check(`${tag}: processing: "Confirming your payment", the card in the centre, nothing says paid yet`,
        await page.isVisible(".zgc-stage") && (await h1(page)) === "Confirming your payment" && !(await page.isVisible("text=Payment received")));
      check(`${tag}: processing: focus on the status heading`, (await focused(page)) === "zgc-status");
      check(`${tag}: processing: the live region says so`, (await page.locator(".zgc [aria-live]").innerText()).includes("Confirming your payment"));
      check(`${tag}: processing: the card still has no digits`, !/\d/.test(await cardText(page)));
      await shot(page, look, width, "processing", axeSource);

      await page.waitForSelector(".zgc.is-confirmed", { timeout: 15000 }).catch(() => {});
      await page.waitForTimeout(4200);   // the flip, the check drawing and the glow's two pulses have finished
      check(`${tag}: confirmed only by the server: Payment received, the title follows`, (await page.locator("#zgc-status").innerText()) === "Payment received" && (await h1(page)) === "You're all set");
      check(`${tag}: confirmed: brand and last 4 as the server returned them, nothing else`, /\bVisa\b/.test(await cardText(page)) && (await cardText(page)).includes("ending 4242") && !/\d{5,}/.test(await cardText(page)));
      check(`${tag}: confirmed: the card is the look's success colour`, await page.evaluate(() => {
        const face = document.querySelector(".zgc-stage .zgc-card-done"), probe = document.createElement("i");
        if (!face) return false;
        probe.style.color = "var(--zella-success)"; document.body.append(probe);
        const want = getComputedStyle(probe).color; probe.remove();
        return getComputedStyle(face).backgroundColor === want && getComputedStyle(face).visibility === "visible" && getComputedStyle(document.querySelector(".zgc-stage .zgc-card-base")).visibility === "hidden";
      }));
      check(`${tag}: confirmed: Continue is offered`, await page.isVisible("button:has-text('Continue')"));
      check(`${tag}: confirmed: the summary keeps the server's amount`, (await page.locator(".zgc-total strong").innerText()) === "$898");
      await shot(page, look, width, "confirmed", axeSource);
      check(`${tag}: no page errors`, errors.length === 0, errors.join("; "));
      check(`${tag}: nothing left this machine`, hits.length === 0, hits.join(", "));
      await ctx.close();

      // payments off: opens soon, can be passed
      const off = await open(browser, { look, viewport: width.viewport, seeded: seededOff, scenario: "" });
      await off.page.waitForSelector("text=Payment opens here soon", { timeout: 10000 }).catch(() => {});
      check(`${look.name} ${width.name}: payments off: opens soon, Continue, no Pay button`,
        await off.page.isVisible("#zgc-status:has-text('Payment opens here soon')") && await off.page.isVisible("button:has-text('Continue')") && !(await off.page.isVisible("button:has-text('Pay securely')")));
      check(`${look.name} ${width.name}: payments off: nothing is due today, the amount is due when payment opens`,
        (await off.page.locator(".zgc-total").innerText()).replace(/\s+/g, " ") === "Due when payment opens $898");
      await shot(off.page, look, width, "off", axeSource);
      check(`${look.name} ${width.name}: payments off: nothing left this machine`, off.hits.length === 0, off.hits.join(", "));
      await off.ctx.close();
    }

    // reduced motion, in this look: no blur, no flight, the states simply change
    const rm = await open(browser, { look, viewport: { width: 1440, height: 900 }, seeded: seededPay, scenario: "pay", reduced: true });
    await rm.page.click("button:has-text('Pay securely')");
    await rm.page.waitForSelector(".zgc-standin", { timeout: 10000 }).catch(() => {});
    await rm.page.click("button:has-text('Complete the stand in payment')");
    await rm.page.waitForSelector(".zgc-stage", { timeout: 8000 }).catch(() => {});
    const motion = await rm.page.evaluate(() => {
      const stage = getComputedStyle(document.querySelector(".zgc-stage")), card = document.querySelector(".zgc-stage .zgc-card");
      const ring = document.querySelector(".zgc-ring"), shimmer = card.querySelector(".zgc-card-shimmer");
      return { blur: stage.backdropFilter, anim: stage.animationName, fly: card.classList.contains("zgc-fly"), cardAnim: getComputedStyle(card).animationName,
        transition: getComputedStyle(card.querySelector(".zgc-card-inner")).transitionDuration,
        ring: ring ? getComputedStyle(ring).animationName : "none", shimmer: getComputedStyle(shimmer).animationName };
    });
    check(`${look.name}: reduced motion: no blur, no fade, no flight, no colour fade`,
      motion.blur === "none" && motion.anim === "none" && !motion.fly && motion.cardAnim === "none" && parseFloat(motion.transition) < 0.001 && motion.ring === "none" && motion.shimmer === "none", JSON.stringify(motion));
    await rm.page.waitForSelector(".zgc.is-confirmed", { timeout: 15000 }).catch(() => {});
    check(`${look.name}: reduced motion: still reaches Payment received through the server`, await rm.page.isVisible("#zgc-status:has-text('Payment received')"));
    check(`${look.name}: reduced motion: the success face shows without turning`, await rm.page.evaluate(() => {
      const inner = document.querySelector(".zgc-stage .zgc-card-inner"), done = document.querySelector(".zgc-stage .zgc-card-done");
      return getComputedStyle(inner).transform === "none" && getComputedStyle(done).visibility === "visible" && getComputedStyle(done.querySelector(".zgc-check path")).animationName === "none";
    }));
    await rm.ctx.close();
  }

  // 320 wide: the layout holds in the narrowest phone (no screenshots)
  for (const look of [LOOKS[0], LOOKS[3]]) {
    const n = await open(browser, { look, viewport: { width: 320, height: 640 }, seeded: seededPay, scenario: "pay" });
    check(`${look.name} 320: ready, no horizontal scroll`, !(await overflow(n.page)));
    await n.page.click("button:has-text('Pay securely')");
    await n.page.waitForSelector(".zgc-standin", { timeout: 10000 }).catch(() => {});
    check(`${look.name} 320: form, no horizontal scroll`, !(await overflow(n.page)));
    await n.ctx.close();
  }

  // back from a redirect payment method (Stripe's return_url): confirmed through the server, the address bar tidied
  {
    const r = await open(browser, { look: LOOKS[0], viewport: { width: 1440, height: 900 }, seeded: seededPay, scenario: "pay" });
    await r.page.click("button:has-text('Pay securely')");
    await r.page.waitForSelector(".zgc-standin", { timeout: 10000 }).catch(() => {});
    await r.page.click("button:has-text('Complete the stand in payment')");
    await r.page.goto(`${APP}/welcome/setup?scenario=pay&checkout=return&session_id=cs_test_return`);
    await r.page.waitForSelector(".zgc.is-confirmed", { timeout: 15000 }).catch(() => {});
    check("return: confirmed through the server after a redirect", await r.page.isVisible("#zgc-status:has-text('Payment received')"));
    check("return: the session id is gone from the address bar", !r.page.url().includes("session_id") && !r.page.url().includes("checkout="));
    check("return: nothing left this machine", r.hits.length === 0, r.hits.join(", "));
    await r.ctx.close();
  }
  // VIDEO=<folder>: a recording of pay -> processing -> confirmed in the Zella Voice look and Glass over a picture
  if (process.env.VIDEO) {
    fs.mkdirSync(process.env.VIDEO, { recursive: true });
    for (const look of [LOOKS[0], LOOKS[3]]) {
      const v = await open(browser, { look, viewport: { width: 1440, height: 900 }, seeded: seededPay, scenario: "pay", video: process.env.VIDEO });
      await v.page.waitForTimeout(800);
      await v.page.hover(".zgc-pay .zgc-card"); await v.page.waitForTimeout(900);
      await v.page.click("button:has-text('Pay securely')");
      await v.page.waitForSelector(".zgc-standin", { timeout: 10000 }).catch(() => {});
      await v.page.waitForTimeout(1200);
      await v.page.click("button:has-text('Complete the stand in payment')");
      await v.page.waitForSelector(".zgc.is-confirmed", { timeout: 15000 }).catch(() => {});
      await v.page.waitForTimeout(4500);
      const rec = v.page.video();
      await v.ctx.close();
      const to = path.join(process.env.VIDEO, `pay-motion-${look.name}-1440.webm`);
      fs.renameSync(await rec.path(), to);
      console.log(`video ${to}`);
    }
  }
  await browser.close();
  console.log(`${passes} passed, ${fails} failed`);
  process.exit(fails ? 1 : 0);
})();
