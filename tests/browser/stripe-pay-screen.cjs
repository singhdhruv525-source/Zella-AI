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
const { loadAxe } = require("./axe.cjs");
const APP = process.env.APP_URL ?? "http://localhost:5150";
const SHOTS = process.env.SHOTS ?? path.join(process.cwd(), "pay-shots");
if (!["localhost", "127.0.0.1"].includes(new URL(APP).hostname)) { console.error("APP_URL must be a local preview"); process.exit(2); }
fs.mkdirSync(SHOTS, { recursive: true });
let fails = 0, passes = 0;
const check = (name, ok, detail = "") => { console.log(`${ok ? "PASS" : "FAIL"} ${name}${detail ? " - " + detail : ""}`); if (ok) passes++; else fails++; };

const { LOOKS, WIDTHS, contrast, axeCard, overflow, cardText, h1, focused, zellaOnCard, mockHasInputs } = require("./pay-helpers.cjs");

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

async function shot(page, look, width, state, axeSource) {
  const file = path.join(SHOTS, `pay-${look.name}-${state}-${width.name}.png`);
  await page.screenshot({ path: file, fullPage: true });
  const tag = `${look.name} ${width.name} ${state}`;
  check(`${tag}: no horizontal scroll`, !(await overflow(page)));
  const c = await contrast(page);
  check(`${tag}: AA contrast for all ${c.n} texts`, c.n > 0 && c.bad.length === 0, c.bad.slice(0, 4).join("; "));
  const ax = await axeCard(page, axeSource);
  check(`${tag}: axe finds no serious problem in the page card`, ax.length === 0, ax.slice(0, 3).join("; "));
  check(`${tag}: no card field of ours, and no input in the stand in's picture of Stripe's form`, (await mockHasInputs(page)) === 0);
  check(`${tag}: the card never shows the Zella Voice name`, !(await zellaOnCard(page)));
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
      check(`${tag}: Payment details holds the stand in's picture of Stripe's form, clearly badged`, await page.isVisible(".zgc-pay .zgc-standin") && await page.isVisible("text=Preview of Stripe's form")
        && await page.locator(".zgc-mock-fields[aria-hidden='true']").count() === 1);
      check(`${tag}: Stripe.js is never loaded by the stand in`, await page.evaluate(() => ![...document.scripts].some((s) => s.src.includes("stripe.com"))));
      await shot(page, look, width, "form", axeSource);

      await page.click(".zgc-standin button:has-text('Pay $898')");
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
      check(`${tag}: confirmed only by the server: Payment received, the title follows`, (await page.locator("#zgc-status").innerText()) === "Payment received" && (await h1(page)) === "Payment confirmed");
      check(`${tag}: confirmed: the issuing bank as the server returned it, in the corner`, (await page.locator(".zgc-stage .zgc-card-done .zgc-card-issuer").innerText()) === "Test Bank");
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
    await rm.page.click(".zgc-standin button:has-text('Pay $898')");
    await rm.page.waitForSelector(".zgc-stage", { timeout: 8000 }).catch(() => {});
    const motion = await rm.page.evaluate(() => {
      const stage = getComputedStyle(document.querySelector(".zgc-stage")), card = document.querySelector(".zgc-stage .zgc-card");
      const ring = document.querySelector(".zgc-ring"), shimmer = card.querySelector(".zgc-card-shimmer");
      return { blur: stage.backdropFilter, anim: stage.animationName, fly: document.querySelector(".zgc-stage-card").classList.contains("zgc-fly"), cardAnim: getComputedStyle(document.querySelector(".zgc-stage-card")).animationName,
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

  // the issuer is text, never markup: a bank name with angle brackets shows as typed and adds no element
  {
    const seededHtml = await seed("payhtml");
    const x = await open(browser, { look: LOOKS[0], viewport: { width: 1440, height: 900 }, seeded: seededHtml, scenario: "payhtml" });
    await x.page.click("button:has-text('Pay securely')");
    await x.page.waitForSelector(".zgc-standin", { timeout: 10000 }).catch(() => {});
    await x.page.click(".zgc-standin button:has-text('Pay $898')");
    await x.page.waitForSelector(".zgc.is-confirmed", { timeout: 15000 }).catch(() => {});
    const issuer = await x.page.evaluate(() => { const n = document.querySelector(".zgc-stage .zgc-card-done .zgc-card-issuer"); return { text: n?.textContent, kids: n?.children.length }; });
    check("issuer: shown as plain text, escaped, never markup", issuer.text === "<b>Bold Bank</b>" && issuer.kids === 0, JSON.stringify(issuer));
    check("issuer: no script ran", x.errors.length === 0, x.errors.join("; "));
    await x.ctx.close();
  }

  // back from a redirect payment method (Stripe's return_url): confirmed through the server, the address bar tidied
  {
    const r = await open(browser, { look: LOOKS[0], viewport: { width: 1440, height: 900 }, seeded: seededPay, scenario: "pay" });
    await r.page.click("button:has-text('Pay securely')");
    await r.page.waitForSelector(".zgc-standin", { timeout: 10000 }).catch(() => {});
    await r.page.click(".zgc-standin button:has-text('Pay $898')");
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
      await v.page.hover(".zgc-cardcol .zgc-card"); await v.page.waitForTimeout(900);
      await v.page.click("button:has-text('Pay securely')");
      await v.page.waitForSelector(".zgc-standin", { timeout: 10000 }).catch(() => {});
      await v.page.waitForTimeout(1200);
      await v.page.click(".zgc-standin button:has-text('Pay $898')");
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
