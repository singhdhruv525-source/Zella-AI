// The owner onboarding Pay screen as a glass checkout (owner, 27 Nov 2026), in a real browser, against the stand in api
// (web/src/onboarding/fakeApi.js). The stand in brings its own stand in for Stripe's embedded form, so Stripe.js is
// never loaded and nothing reaches Supabase or Stripe: every request off this machine is refused here and counted.
//
// Every state, in every Zella Voice look, at 1440x900 and 390 wide (and 320 for the layout):
//   ready ...... Ready to pay, the summary with the server's amount, the add ons, the required "I agree" box
//   addons ..... one add on ticked (a receipt line, the total and Pay follow) and the box ticked
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

const { agree, startPay, consentWords, pressBlocked, enforcePayPageCsp, watchCsp, cspViolations, backFace, LOOKS, WIDTHS, contrast, axeCard, overflow, cardText, h1, focused, zellaOnCard, mockHasInputs, fillCard, waitFilled, onlyLast4AndExpiry, addressMock } = require("./pay-helpers.cjs");

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
    if (["localhost", "127.0.0.1"].includes(url.hostname)) return enforcePayPageCsp(ctx, route);
    if (["fonts.googleapis.com", "fonts.gstatic.com"].includes(url.hostname)) return route.continue();
    hits.push(`${route.request().method()} ${url.hostname}${url.pathname}`);
    return route.fulfill({ status: 503, contentType: "application/json", body: "{}" });
  });
  await watchCsp(ctx);
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
      // the required "I agree" box (owner, 27 Nov 2026): unticked, Pay disabled until it is ticked, the server's amounts
      const words0 = (await consentWords(page));
      check(`${tag}: agree: a real labelled checkbox above Pay, unticked; the words use the server's amounts (Auto pay on)`, !(await page.isChecked("#zgc-consent"))
        && words0 === "I agree to the Terms and Privacy Policy and authorize Zella Voice to charge this card $898 today and $249 on each renewal until I cancel.", words0);
      check(`${tag}: agree: Terms and Privacy Policy open in a new tab`, (await page.getAttribute(".zgc-consent a[href='/terms']", "target")) === "_blank"
        && (await page.getAttribute(".zgc-consent a[href='/privacy']", "target")) === "_blank" && (await page.getAttribute(".zgc-consent a[href='/privacy']", "rel")).includes("noopener"));
      check(`${tag}: agree: Pay looks disabled until the box is ticked`, (await page.getAttribute(".zgc-pay-foot button:has-text('Continue to pay')", "aria-disabled")) === "true");
      await pressBlocked(page, ".zgc-pay-foot button:has-text('Continue to pay')");
      check(`${tag}: agree: Pay without ticking announces the error in the live region and opens nothing`,
        (await page.locator(".zgc-consent [role=alert]").innerText()) === "Tick the box to agree before you pay." && await page.isVisible("text=Ready to pay") && !(await page.isVisible(".zgc-slot")));
      // add ons in the receipt panel: tick box rows grouped by type, server prices, total and Pay follow
      check(`${tag}: add ons: tick box rows grouped Minutes, Texts, Emails, each with name, description and "one time" price`,
        (await page.locator(".zgc-addon-group legend").allTextContents()).join(",") === "Minutes,Texts,Emails"
        && (await page.locator(".zgc-addon").first().innerText()).replace(/\s+/g, " ").includes("100 AI minutes Extra call time for your AI receptionist $29 one time")
        && (await page.locator(".zgc-addon input[type=checkbox]").count()) === (await page.locator(".zgc-addon").count()));
      await page.click(".zgc-addon:has-text('100 AI minutes')");
      await page.waitForTimeout(150);
      check(`${tag}: add ons: ticking adds a receipt line, the total and the Pay button follow ($898 + $29 = $927)`,
        (await page.locator(".zgc-total strong").innerText()) === "$927" && await page.isVisible(".zgc-lines dt:has-text('100 AI minutes')")
        && await page.isVisible(".zgc-pay-foot button:has-text('Continue to pay $927')") && await page.isVisible("text=Add ons are one time and never renew."));
      check(`${tag}: add ons: the new total is announced politely`, (await page.locator(".zgc-summary [aria-live=polite]").innerText()) === "Total due today $927.");
      check(`${tag}: agree: the words follow the total and say add ons are one time`, (await consentWords(page))
        === "I agree to the Terms and Privacy Policy and authorize Zella Voice to charge this card $927 today and $249 on each renewal until I cancel. Add ons are one time and never renew.");
      await agree(page);
      check(`${tag}: agree: ticking it clears the error and Pay is no longer blocked`, (await page.getAttribute(".zgc-pay-foot button:has-text('Continue to pay')", "aria-disabled")) === null
        && (await page.locator(".zgc-consent [role=alert]").innerText()) === "");
      await shot(page, look, width, "addons", axeSource);

      await page.click(".zgc-pay-foot button:has-text('Continue to pay $927')");
      await page.waitForSelector(".zgc-slot .zgc-slot-text", { timeout: 10000 }).catch(() => {});
      check(`${tag}: Payment details: the stand in's card fields and billing address (no inputs), clearly badged`, await page.isVisible(".zgc-pay .zgc-addr-mock") && await page.isVisible("text=Preview of Stripe's form")
        && await page.locator(".zgc-slot").count() === 3 && await page.locator(".zgc-fields input").count() === 0);
      const addr = await addressMock(page);
      check(`${tag}: billing address: prefilled from the business, United States format`, addr?.country === "US" && addr.labels.includes("ZIP code") && addr.labels.includes("State")
        && addr.values.line1 === "214 Maple Street" && addr.values.name === "", JSON.stringify(addr));
      check(`${tag}: the address never shows on the card`, !(await cardText(page)).includes("Maple"));
      check(`${tag}: Auto pay: "Pay automatically each renewal", on by default, with what it means`, (await page.getAttribute(".zgc-autopay [role=switch]", "aria-checked")) === "true"
        && (await page.locator(".zgc-autopay-note").innerText()) === "Stripe charges this card on each renewal date.");
      check(`${tag}: Pay waits until every card field is complete`, await page.isDisabled(".zgc-pay-foot button:has-text('Pay $927')"));
      await fillCard(page);
      await page.waitForSelector(".zgc-cardcol .zgc-card.is-back", { timeout: 10000 }).catch(() => {});
      check(`${tag}: typing the security code turns the card over`, await page.locator(".zgc-cardcol .zgc-card.is-back").count() === 1);
      const bf = await backFace(page);   // after the turn has settled
      check(`${tag}: once turned, the back face is shown and its magnetic stripe is dark`, bf?.isBack === true && bf.visible === true && bf.luminance !== null && bf.luminance < 0.12, JSON.stringify(bf));
      await shot(page, look, width, "card-back", axeSource);
      await waitFilled(page);
      await page.waitForTimeout(900);
      const filled = await page.evaluate(() => { const c = document.querySelector(".zgc-cardcol .zgc-card-front"); return { number: c.querySelector(".zgc-cf-number").textContent, exp: c.querySelector(".zgc-cf-valid > span").textContent, brand: c.querySelector(".zgc-cf-brand").textContent, name: c.querySelector(".zgc-cf-name").textContent }; });
      check(`${tag}: filled from Stripe's preview: last 4, expiry, brand, and the name`, filled.number === "•••• •••• •••• 4242" && filled.exp === "12/28" && filled.brand === "Visa" && filled.name === "JORDAN LEE", JSON.stringify(filled));
      check(`${tag}: the card never shows more than the last 4 and the expiry`, onlyLast4AndExpiry(await cardText(page)));
      check(`${tag}: the name typed in the billing address mirrors on the card; the address doesn't`, (await addressMock(page))?.values.name === "Jordan Lee"
        && !/Maple|Springfield|62701/.test(await cardText(page)));
      check(`${tag}: Stripe.js is never loaded by the stand in`, await page.evaluate(() => ![...document.scripts].some((s) => s.src.includes("stripe.com"))));
      await shot(page, look, width, "form", axeSource);

      await page.click(".zgc-pay-foot button:has-text('Pay $927')");
      await page.waitForFunction(() => document.querySelector("h1")?.textContent.includes("Confirming your payment"), null, { timeout: 8000 }).catch(() => {});
      await page.waitForTimeout(150);
      check(`${tag}: processing: "Confirming your payment", the card in the centre, nothing says paid yet`,
        await page.isVisible(".zgc-stage") && (await h1(page)) === "Confirming your payment" && !(await page.isVisible("text=Payment received")));
      check(`${tag}: processing: focus on the status heading`, (await focused(page)) === "zgc-status");
      check(`${tag}: processing: the live region says so`, (await page.locator(".zgc > p[role=status]").innerText()).includes("Confirming your payment"));
      check(`${tag}: processing: still only the last 4 and the expiry`, onlyLast4AndExpiry(await cardText(page)));
      await shot(page, look, width, "processing", axeSource);

      await page.waitForSelector(".zgc.is-confirmed", { timeout: 15000 }).catch(() => {});
      await page.waitForTimeout(4200);   // the flip, the check drawing and the glow's two pulses have finished
      check(`${tag}: confirmed only by the server: Payment received, the title follows`, (await page.locator("#zgc-status").innerText()) === "Payment received" && (await h1(page)) === "Payment confirmed");
      check(`${tag}: confirmed: the issuing bank as the server returned it, in the corner`, (await page.locator(".zgc-stage .zgc-card-done .zgc-cf-issuer").innerText()) === "Test Bank");
      check(`${tag}: confirmed: brand and last 4 as the server returned them, nothing else`, /\bVisa\b/.test(await cardText(page)) && (await cardText(page)).includes("•••• •••• •••• 4242") && !/\d{5,}/.test(await cardText(page)));
      check(`${tag}: confirmed: the card is the look's success colour`, await page.evaluate(() => {
        const face = document.querySelector(".zgc-stage .zgc-card-done"), probe = document.createElement("i");
        if (!face) return false;
        probe.style.color = "var(--zella-success)"; document.body.append(probe);
        const want = getComputedStyle(probe).color; probe.remove();
        return getComputedStyle(face).backgroundColor === want && getComputedStyle(face).visibility === "visible" && getComputedStyle(document.querySelector(".zgc-stage .zgc-card-front")).visibility === "hidden";
      }));
      check(`${tag}: confirmed: Continue is offered`, await page.isVisible("button:has-text('Continue')"));
      check(`${tag}: confirmed: the summary keeps the server's amount, the plan and the add on in one payment`, (await page.locator(".zgc-total strong").innerText()) === "$927");
      await shot(page, look, width, "confirmed", axeSource);
      check(`${tag}: the Pay step came with its ENFORCING policy and nothing was blocked`, (ctx.__cspServed ?? 0) >= 1 && (await cspViolations(page)).length === 0, (await cspViolations(page)).join("; "));
      check(`${tag}: no page errors`, errors.length === 0, errors.join("; "));
      check(`${tag}: nothing left this machine`, hits.length === 0, hits.join(", "));
      await ctx.close();

      // payments off: opens soon, can be passed
      const off = await open(browser, { look, viewport: width.viewport, seeded: seededOff, scenario: "" });
      await off.page.waitForSelector("text=Payment opens here soon", { timeout: 10000 }).catch(() => {});
      check(`${look.name} ${width.name}: payments off: opens soon, Continue, no Pay button`,
        await off.page.isVisible("#zgc-status:has-text('Payment opens here soon')") && await off.page.isVisible("button:has-text('Continue')") && !(await off.page.isVisible("button:has-text('Continue to pay')")) && !(await off.page.isVisible("#zgc-consent")));
      check(`${look.name} ${width.name}: payments off: nothing is due today, the amount is due when payment opens`,
        (await off.page.locator(".zgc-total").innerText()).replace(/\s+/g, " ") === "Due when payment opens $898");
      await shot(off.page, look, width, "off", axeSource);
      check(`${look.name} ${width.name}: payments off: nothing left this machine`, off.hits.length === 0, off.hits.join(", "));
      await off.ctx.close();
    }

    // reduced motion, in this look: no blur, no flight, the states simply change
    const rm = await open(browser, { look, viewport: { width: 1440, height: 900 }, seeded: seededPay, scenario: "pay", reduced: true });
    await startPay(rm.page);
    await fillCard(rm.page); await waitFilled(rm.page);
    await rm.page.click(".zgc-pay-foot button:has-text('Pay $898')");
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
    await startPay(n.page);
    await n.page.waitForSelector(".zgc-slot .zgc-slot-text", { timeout: 10000 }).catch(() => {});
    check(`${look.name} 320: form, no horizontal scroll`, !(await overflow(n.page)));
    await n.ctx.close();
  }

  // the issuer is text, never markup: a bank name with angle brackets shows as typed and adds no element
  {
    const seededHtml = await seed("payhtml");
    const x = await open(browser, { look: LOOKS[0], viewport: { width: 1440, height: 900 }, seeded: seededHtml, scenario: "payhtml" });
    await startPay(x.page);
    await fillCard(x.page); await waitFilled(x.page);
    await x.page.click(".zgc-pay-foot button:has-text('Pay $898')");
    await x.page.waitForSelector(".zgc.is-confirmed", { timeout: 15000 }).catch(() => {});
    const issuer = await x.page.evaluate(() => { const n = document.querySelector(".zgc-stage .zgc-card-done .zgc-cf-issuer"); return { text: n?.textContent, kids: n?.children.length }; });
    check("issuer: shown as plain text, escaped, never markup", issuer.text === "<b>Bold Bank</b>" && issuer.kids === 0, JSON.stringify(issuer));
    check("issuer: no script ran", x.errors.length === 0, x.errors.join("; "));
    await x.ctx.close();
  }

  // Auto pay switched off in the checkout: honest words while email is off, and the choice is sent once the server confirms
  {
    const ap = await open(browser, { look: LOOKS[0], viewport: { width: 1440, height: 900 }, seeded: seededPay, scenario: "pay" });
    await startPay(ap.page);
    await ap.page.click(".zgc-autopay [role=switch]");
    await ap.page.waitForTimeout(300);
    check("autopay off in the checkout: says the invoice waits in the CRM (no email promised while email is off)",
      (await ap.page.locator(".zgc-autopay-note").innerText()) === "Your invoice appears in the CRM; pay it there within 3 days.");
    check("agree: Auto pay off changes the words (the owner pays future invoices) and unticks the box, saying why",
      (await consentWords(ap.page)) === "I agree to the Terms and Privacy Policy and authorize Zella Voice to charge this card $898 today. I'll pay future invoices myself."
      && !(await ap.page.isChecked("#zgc-consent")) && (await ap.page.locator(".zgc-consent [role=alert]").innerText()) === "The details changed. Tick the box again to agree to them.");
    await ap.page.screenshot({ path: path.join(SHOTS, "pay-zella-autopay-off-1440.png"), fullPage: true });
    await fillCard(ap.page); await waitFilled(ap.page);
    await pressBlocked(ap.page, ".zgc-pay-foot button:has-text('Pay $898')");
    check("agree: Pay with the box unticked charges nothing and says so", (await ap.page.locator(".zgc-consent [role=alert]").innerText()) === "Tick the box to agree before you pay."
      && !(await ap.page.isVisible(".zgc.is-confirming")));
    await agree(ap.page);
    await ap.page.click(".zgc-pay-foot button:has-text('Pay $898')");
    await ap.page.waitForSelector(".zgc.is-confirming, .zgc.is-confirmed", { timeout: 10000 }).catch(() => {});
    // the choice went with the start and is kept with the checkout (the stand in's own record, as the server keeps it): a
    // closed tab can't lose it (review M2)
    const kept = await ap.page.evaluate(() => JSON.parse(localStorage.getItem("zella.onboardingFake.v2") ?? "{}").autopay_choice);
    check("autopay off: the choice went to the server with the start (a closed tab can't lose it)", kept === false, String(kept));
    await ap.ctx.close();
  }

  // card problems on the Pay step in every look (owner question, 27 Nov 2026)
  {
    const seededDec = await seed("paydeclined"), seededBank = await seed("paybank");
    const W = { name: "1440", viewport: { width: 1440, height: 900 } };
    for (const look of LOOKS) {
      const i = await open(browser, { look, viewport: W.viewport, seeded: seededPay, scenario: "pay" });
      await startPay(i.page); await i.page.waitForSelector(".zgc-slot .zgc-slot-text", { timeout: 10000 }).catch(() => {});
      await i.page.click("button:has-text('Show wrong card details')"); await i.page.waitForSelector("#zgc-e-address:not(:empty)", { timeout: 8000 }).catch(() => {}); await i.page.waitForTimeout(1200);
      const fe = await i.page.evaluate(() => Object.fromEntries([...document.querySelectorAll(".zgc-field-error")].map((e) => [e.id.replace("zgc-e-", ""), e.textContent])));
      check(`${look.name}: wrong details inline under Stripe's fields, Pay disabled, no last 4`, fe.number === "Your card number is invalid." && fe.expiry === "Your card's expiration year is in the past."
        && fe.cvc === "Your card's security code is incomplete." && fe.address === "Your ZIP code is incomplete." && await i.page.isDisabled(".zgc-pay-foot button:has-text('Pay $898')") && !/\d{4}/.test(await cardText(i.page)), JSON.stringify(fe));
      await shot(i.page, look, W, "invalid", axeSource);
      await i.ctx.close();
      const d = await open(browser, { look, viewport: W.viewport, seeded: seededDec, scenario: "paydeclined" });
      await startPay(d.page); await fillCard(d.page); await waitFilled(d.page);
      await d.page.click(".zgc-pay-foot button:has-text('Pay $898')");
      await d.page.waitForSelector(".zgc-decline", { timeout: 10000 }).catch(() => {});
      check(`${look.name}: declined at payment: in the panel, nothing charged, Try another card; the receipt and the agree box stay`, (await d.page.locator(".zgc-decline strong").innerText().catch(() => "")) === "Your card was declined"
        && await d.page.isVisible(".zgc-decline button:has-text('Try another card')") && (await d.page.locator(".zgc-total strong").innerText()) === "$898" && await d.page.isChecked("#zgc-consent"));
      await shot(d.page, look, W, "declined", axeSource);
      await d.page.click(".zgc-decline button:has-text('Try another card')");
      await fillCard(d.page); await waitFilled(d.page);
      await d.page.click(".zgc-pay-foot button:has-text('Pay $898')");
      await d.page.waitForSelector(".zgc.is-confirmed", { timeout: 15000 }).catch(() => {});
      check(`${look.name}: another card pays the same session, confirmed by the server`, (await d.page.locator("#zgc-status").innerText().catch(() => "")) === "Payment received");
      await d.ctx.close();
      const b = await open(browser, { look, viewport: W.viewport, seeded: seededBank, scenario: "paybank" });
      await startPay(b.page); await fillCard(b.page); await waitFilled(b.page);
      await b.page.click(".zgc-pay-foot button:has-text('Pay $898')");
      await b.page.waitForSelector(".zgc-bank-preview", { timeout: 10000 }).catch(() => {});
      check(`${look.name}: the bank's check: a labelled preview, "Waiting for your bank to confirm", the card still`, await b.page.isVisible(".zgc-bank-preview .zgc-mock-badge")
        && (await b.page.locator("#zgc-status").innerText()) === "Waiting for your bank to confirm" && (await b.page.locator(".zgc.is-bankwait").count()) === 1);
      await shot(b.page, look, W, "bank-verify", axeSource);
      await b.page.click(".zgc-bank-preview button:has-text('Fail')");
      await b.page.waitForSelector(".zgc-decline", { timeout: 10000 }).catch(() => {});
      check(`${look.name}: the bank's check failed: "Your bank didn't confirm the payment. Nothing was charged."`, (await b.page.locator(".zgc-decline p").innerText().catch(() => "")).startsWith("Your bank didn't confirm the payment. Nothing was charged."));
      await shot(b.page, look, W, "bank-failed", axeSource);
      await b.page.click(".zgc-pay-foot button:has-text('Pay $898')");
      await b.page.waitForSelector(".zgc-bank-preview", { timeout: 10000 }).catch(() => {});
      await b.page.click(".zgc-bank-preview button:has-text('Approve')");
      await b.page.waitForSelector(".zgc.is-confirmed", { timeout: 15000 }).catch(() => {});
      check(`${look.name}: the bank approved: Payment received only from the server`, (await b.page.locator("#zgc-status").innerText().catch(() => "")) === "Payment received");
      check(`${look.name}: card problems: no page errors`, b.errors.length === 0 && d.errors.length === 0, [...b.errors, ...d.errors].join("; "));
      await b.ctx.close();
    }
  }

  // add ons changed while Stripe's form is open: back to Pay, the old session expired first, one session at a time
  {
    const c = await open(browser, { look: LOOKS[0], viewport: { width: 1440, height: 900 }, seeded: seededPay, scenario: "pay" });
    await startPay(c.page, "Continue to pay $898");
    await c.page.waitForSelector(".zgc-slot .zgc-slot-text", { timeout: 10000 }).catch(() => {});
    await c.page.click(".zgc-addon:has-text('500 texts')");
    await c.page.waitForTimeout(300);
    check("add ons: ticking one while Stripe's form is open goes back to Pay for the new total, the box unticked", await c.page.isVisible("text=Ready to pay")
      && !(await c.page.isVisible(".zgc-slot")) && !(await c.page.isChecked("#zgc-consent")) && await c.page.isVisible(".zgc-pay-foot button:has-text('Continue to pay $916')"));
    // keyboard: Tab reaches the tick boxes and Space toggles them
    await c.page.focus(".zgc-addon:has-text('500 texts') input");
    await c.page.keyboard.press("Space");
    check("add ons: a real checkbox: Space unticks it, the total goes back", (await c.page.locator(".zgc-total strong").innerText()) === "$898");
    await c.page.keyboard.press("Space");
    await c.page.focus("#zgc-consent"); await c.page.keyboard.press("Space");
    await c.page.click(".zgc-pay-foot button:has-text('Continue to pay $916')");
    await c.page.waitForSelector(".zgc-slot .zgc-slot-text", { timeout: 10000 }).catch(() => {});
    const st = await c.page.evaluate(() => JSON.parse(localStorage.getItem("zella.onboardingFake.v2") ?? "{}"));
    check("add ons: the new selection got a new session only after the old one was expired", st.sessions_expired === 1 && st.sessions_made === 2 && st.checkout_amount === 91600
      && st.checkout_selection === "texts_500", JSON.stringify({ e: st.sessions_expired, m: st.sessions_made, a: st.checkout_amount }));
    check("add ons: no page errors", c.errors.length === 0, c.errors.join("; "));
    await c.ctx.close();
  }

  // double payment protections on the Pay step (owner priority, 27 Nov 2026)
  {
    const d = await open(browser, { look: LOOKS[0], viewport: { width: 1440, height: 900 }, seeded: seededPay, scenario: "pay" });
    await startPay(d.page);
    await fillCard(d.page); await waitFilled(d.page);
    await d.page.dblclick(".zgc-pay-foot button:has-text('Pay $898')").catch(() => {});
    await d.page.keyboard.press("Enter").catch(() => {});
    await d.page.waitForSelector(".zgc.is-confirming, .zgc.is-confirmed", { timeout: 8000 }).catch(() => {});
    check("case 7: a double click and Enter on Pay make one confirm", (await d.page.evaluate(() => window.__zgcConfirms)) === 1, String(await d.page.evaluate(() => window.__zgcConfirms)));
    await d.page.reload();
    await d.page.waitForSelector(".zgc", { timeout: 10000 }).catch(() => {});
    await d.page.waitForTimeout(400);
    check("case 1: a reload while confirming goes back to confirming from the server, with no Pay", await d.page.isVisible(".zgc.is-confirming, .zgc.is-pending, .zgc.is-confirmed")
      && (await d.page.locator("button:has-text('Continue to pay'), button:has-text('Pay $898')").count()) === 0);
    await d.page.waitForSelector(".zgc.is-confirmed", { timeout: 15000 }).catch(() => {});
    await d.page.goBack().catch(() => {}); await d.page.goForward().catch(() => {});
    await d.page.waitForSelector(".zgc", { timeout: 10000 }).catch(() => {});
    await d.page.waitForTimeout(400);
    check("case 2: Back and Forward after success show it confirmed, nothing to pay", await d.page.isVisible("#zgc-status:has-text('Payment received')")
      && (await d.page.locator("button:has-text('Continue to pay')").count()) === 0);
    await d.ctx.close();
    // case 9: a stale or duplicate return from Stripe: never trusted; the server is asked and the query is removed
    const q = await open(browser, { look: LOOKS[0], viewport: { width: 1440, height: 900 }, seeded: seededPay, scenario: "pay",
      query: "&checkout=return&session_id=cs_test_stale&payment_intent=pi_stale&redirect_status=succeeded" });
    await q.page.waitForTimeout(800);
    check("case 9: stale return parameters prove nothing: removed from the address, nothing says paid", !/session_id|payment_intent|redirect_status|checkout=/.test(q.page.url())
      && !(await q.page.isVisible("#zgc-status:has-text('Payment received')")));
    await q.ctx.close();
  }

  // Stripe.js can't load on the Pay step: Stripe's own Checkout page at once, as the fallback (owner decision, 27 Nov 2026)
  {
    const seededJs = await seed("payjsfail");
    const j = await open(browser, { look: LOOKS[0], viewport: { width: 1440, height: 900 }, seeded: seededJs, scenario: "payjsfail" });
    const going = j.page.waitForRequest((r) => r.url().startsWith("https://checkout.stripe.com/"), { timeout: 10000 }).catch(() => null);
    await startPay(j.page);
    const req = await going;
    check("Stripe.js didn't load: the Pay step goes to Stripe's own page (hosted fallback)", Boolean(req) && req.url() === "https://checkout.stripe.com/c/pay/cs_standin_hosted");
    await j.ctx.close();
  }

  // back from a redirect payment method (Stripe's return_url): confirmed through the server, the address bar tidied
  {
    const r = await open(browser, { look: LOOKS[0], viewport: { width: 1440, height: 900 }, seeded: seededPay, scenario: "pay" });
    await startPay(r.page);
    await fillCard(r.page); await waitFilled(r.page);
    await r.page.click(".zgc-pay-foot button:has-text('Pay $898')");
    await r.page.waitForSelector(".zgc.is-confirming, .zgc.is-confirmed", { timeout: 10000 }).catch(() => {});   // Stripe has it, then the bank's redirect
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
      // an add on and the agree box (owner, 27 Nov 2026)
      await v.page.click(".zgc-addon:has-text('100 AI minutes')"); await v.page.waitForTimeout(900);
      await pressBlocked(v.page, ".zgc-pay-foot button:has-text('Continue to pay')"); await v.page.waitForTimeout(1200);   // the error, announced
      await agree(v.page); await v.page.waitForTimeout(900);
      await v.page.click(".zgc-pay-foot button:has-text('Continue to pay')");
      await fillCard(v.page);
      await waitFilled(v.page);
      await v.page.waitForTimeout(1200);
      await v.page.click(".zgc-pay-foot button:has-text('Pay $927')");
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
