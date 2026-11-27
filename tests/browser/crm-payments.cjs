// Paying from inside the CRM (owner decision, 27 Nov 2026: "auto charge plus Pay now") in a real browser, against the
// billing stand in (web/src/billing/fakeBillingApi.js), which mounts a static picture of Stripe's form and never loads
// Stripe.js. Nothing reaches Supabase or Stripe: every request off this machine is refused here and counted.
//
// In every Zella Voice look, at 1440x900, 390 and 320 wide:
//   list ............ the renewal line with the saved card, Update card, invoices with Pay now, packs with Buy
//   paying .......... Pay now: the glass checkout, Payment details with the picture of Stripe's form and our Pay button
//   processing ...... after paying: "Confirming your payment"
//   confirmed ....... only after the server's later look: "Payment received", the card with issuer, brand and last 4
//   already-paid .... the emailed link for a paid invoice: "This invoice is paid", nothing to pay
//   update-card ..... back from Stripe's card page: the note, the card Stripe has
//   pack-confirm .... buying a pack: the confirm panel with the price and the card it is charged to
//   pack-action ..... the bank wants to confirm: "Confirm with your bank" (then the same intent in Stripe's form)
//   pack-added ...... only after the server grants it
//   no-card ......... no card saved: "There's no card to charge" with Update card
// Each shot: no horizontal scroll, AA contrast from rendered pixels, axe on the page card, no input of ours, and the card
// never shows the Zella Voice name or digits before a payment the server confirmed.
//
// Build and serve a LOCAL copy as in stripe-pay-screen.cjs, then:
//   APP_URL=http://localhost:5150 SHOTS=<folder> [VIDEO=<folder>] node tests/browser/crm-payments.cjs
const { chromium } = require("playwright");
const fs = require("fs");
const path = require("path");
const { loadAxe } = require("./axe.cjs");
const { LOOKS, contrast, axeCard, overflow, cardText, zellaOnCard, mockHasInputs } = require("./pay-helpers.cjs");
const APP = process.env.APP_URL ?? "http://localhost:5150";
const SHOTS = process.env.SHOTS ?? path.join(process.cwd(), "crm-pay-shots");
if (!["localhost", "127.0.0.1"].includes(new URL(APP).hostname)) { console.error("APP_URL must be a local preview"); process.exit(2); }
fs.mkdirSync(SHOTS, { recursive: true });
let fails = 0, passes = 0;
const check = (name, ok, detail = "") => { console.log(`${ok ? "PASS" : "FAIL"} ${name}${detail ? " - " + detail : ""}`); if (ok) passes++; else fails++; };
const BIZ = "00000000-0000-4000-8000-0000000000b1", OPEN = "00000000-0000-4000-8000-0000000000e2";
const WIDTHS = [{ name: "1440", viewport: { width: 1440, height: 900 } }, { name: "390", viewport: { width: 390, height: 844 } }, { name: "320", viewport: { width: 320, height: 700 } }];

async function open(browser, look, viewport, url, { video = null } = {}) {
  const ctx = await browser.newContext({ viewport, deviceScaleFactor: 1, ...(video ? { recordVideo: { dir: video, size: viewport } } : {}) });
  const hits = [];
  await ctx.route((u) => ["http:", "https:"].includes(u.protocol), async (route) => {
    const u = new URL(route.request().url());
    if (["localhost", "127.0.0.1", "fonts.googleapis.com", "fonts.gstatic.com"].includes(u.hostname)) return route.continue();
    hits.push(`${route.request().method()} ${u.hostname}${u.pathname}`);
    return route.fulfill({ status: 503, contentType: "application/json", body: "{}" });
  });
  await ctx.addInitScript((pref) => { if (pref && !sessionStorage.getItem("look")) { localStorage.setItem("zella.appearance.crm", JSON.stringify({ user: null, pref })); sessionStorage.setItem("look", "1"); } }, look.pref);
  const page = await ctx.newPage();
  const errors = []; page.on("pageerror", (e) => errors.push(e.message));
  await page.goto(`${APP}${url}`);
  await page.waitForTimeout(500);
  return { ctx, page, hits, errors };
}

async function shot(page, look, width, state, axeSource) {
  const file = path.join(SHOTS, `crm-${look.name}-${state}-${width.name}.png`);
  await page.screenshot({ path: file, fullPage: true });
  const tag = `${look.name} ${width.name} ${state}`;
  check(`${tag}: no horizontal scroll`, !(await overflow(page)));
  const c = await contrast(page);
  check(`${tag}: AA contrast for all ${c.n} texts`, c.n > 0 && c.bad.length === 0, c.bad.slice(0, 4).join("; "));
  const ax = await axeCard(page, axeSource);
  check(`${tag}: axe finds no serious problem`, ax.length === 0, ax.slice(0, 3).join("; "));
  check(`${tag}: no input of ours, none in the picture of Stripe's form`, (await mockHasInputs(page)) === 0);
  check(`${tag}: the card never shows the Zella Voice name`, !(await zellaOnCard(page)));
}

(async () => {
  const axeSource = loadAxe();
  const browser = await chromium.launch();
  for (const look of LOOKS) {
    for (const width of WIDTHS) {
      const tag = `${look.name} ${width.name}`;
      // ---- the list, then Pay now on the open invoice ----
      const a = await open(browser, look, width.viewport, `/pay?business=${BIZ}&scenario=`);
      await a.page.waitForSelector(".zpay-row", { timeout: 10000 }).catch(() => {});
      check(`${tag}: auto charge: the renewal date and the saved card from Stripe`, (await a.page.locator(".zpay-lead").innerText()).includes("We'll charge your Visa ending 4242"));
      check(`${tag}: the open invoice offers Pay now, the paid one doesn't`, (await a.page.locator(".zpay-row:has-text('ZV-0042') button:has-text('Pay now')").count()) === 1
        && (await a.page.locator(".zpay-row:has-text('ZV-0031') button:has-text('Pay now')").count()) === 0);
      check(`${tag}: Stripe's hosted invoice page stays as a link`, (await a.page.locator(".zpay-row a.zpay-ext").count()) === 2);
      await shot(a.page, look, width, "list", axeSource);
      await a.page.click(".zpay-row:has-text('ZV-0042') button:has-text('Pay now')");
      await a.page.waitForSelector(".zgc", { timeout: 10000 }).catch(() => {});
      check(`${tag}: the glass checkout for the invoice, the amount from the server`, (await a.page.locator(".zgc-total strong").innerText()) === "$249");
      check(`${tag}: the hosted invoice page is the fallback`, await a.page.isVisible("a:has-text(\"Pay on Stripe's invoice page\")"));
      await a.page.click(".zgc-pay button:has-text('Pay now')");
      await a.page.waitForSelector(".zgc-standin", { timeout: 10000 }).catch(() => {});
      check(`${tag}: paying: the picture of Stripe's form in Payment details, our Pay button under it`, await a.page.isVisible(".zgc-pay .zgc-standin") && await a.page.isVisible(".zgc-pay-foot button:has-text('Pay $249')"));
      check(`${tag}: Stripe.js is never loaded by the stand in`, await a.page.evaluate(() => ![...document.scripts].some((s) => s.src.includes("stripe.com"))));
      await shot(a.page, look, width, "paying", axeSource);
      await a.page.click(".zgc-pay-foot button:has-text('Pay $249')");
      await a.page.waitForSelector(".zgc.is-confirming", { timeout: 8000 }).catch(() => {});
      await a.page.waitForTimeout(250);
      check(`${tag}: processing: confirming, nothing says paid`, await a.page.isVisible(".zgc-stage") && !(await a.page.isVisible("#zgc-status:has-text('Payment received')")));
      check(`${tag}: processing: no digits on the card`, !/\d/.test(await cardText(a.page)));
      await shot(a.page, look, width, "processing", axeSource);
      await a.page.waitForSelector(".zgc.is-confirmed", { timeout: 15000 }).catch(() => {});
      await a.page.waitForTimeout(4200);
      check(`${tag}: confirmed only after the server's later look`, (await a.page.locator("#zgc-status").innerText()) === "Payment received");
      const done = await a.page.evaluate(() => { const f = document.querySelector(".zgc-stage .zgc-card-done"); return { issuer: f?.querySelector(".zgc-card-issuer")?.textContent, brand: f?.querySelector(".zgc-card-brand")?.textContent, number: f?.querySelector(".zgc-card-number")?.textContent }; });
      check(`${tag}: confirmed: issuer, brand and last 4 as the server returned them`, done.issuer === "Test Bank" && done.brand === "Visa" && done.number === "ending 4242", JSON.stringify(done));
      await shot(a.page, look, width, "confirmed", axeSource);
      check(`${tag}: no page errors`, a.errors.length === 0, a.errors.join("; "));
      check(`${tag}: nothing left this machine`, a.hits.length === 0, a.hits.join(", "));
      await a.ctx.close();

      // ---- the emailed link for an invoice already paid ----
      const b = await open(browser, look, width.viewport, `/pay/invoice/${OPEN}?scenario=paid`);
      await b.page.waitForSelector(".zgc", { timeout: 10000 }).catch(() => {});
      await b.page.waitForTimeout(300);
      check(`${tag}: already paid: says so, nothing to pay`, (await b.page.locator("#zgc-status").innerText()) === "This invoice is paid" && (await b.page.locator(".zgc-pay-btn").count()) === 0);
      await shot(b.page, look, width, "already-paid", axeSource);
      await b.ctx.close();

      // ---- Update card: Stripe's page, then back here ----
      const u = await open(browser, look, width.viewport, `/pay?business=${BIZ}&scenario=`);
      await u.page.waitForSelector(".zpay-row", { timeout: 10000 }).catch(() => {});
      await u.page.click("button:has-text('Update card')");
      await u.page.waitForSelector(".zpay-note", { timeout: 10000 }).catch(() => {});
      check(`${tag}: update card: back from Stripe's card page, the card Stripe has`, await u.page.isVisible("text=You're back from Stripe") && !u.page.url().includes("card=updated"));
      await shot(u.page, look, width, "update-card", axeSource);
      await u.ctx.close();

      // ---- buying a pack: the confirm panel, the bank wants to confirm, then added ----
      const p = await open(browser, look, width.viewport, `/pay?business=${BIZ}&scenario=packauth`);
      await p.page.waitForSelector(".zpay-row", { timeout: 10000 }).catch(() => {});
      await p.page.click(".zpay-row:has-text('100 AI minutes') button:has-text('Buy')");
      await p.page.waitForSelector(".zgc", { timeout: 10000 }).catch(() => {});
      check(`${tag}: pack: the price from the server and the card it is charged to`, (await p.page.locator(".zgc-total strong").innerText()) === "$29" && await p.page.isVisible("text=Charged to your Visa ending 4242"));
      await shot(p.page, look, width, "pack-confirm", axeSource);
      await p.page.click(".zgc-pay-foot button:has-text('Pay $29')");
      await p.page.waitForSelector(".zgc.is-error", { timeout: 15000 }).catch(() => {});
      check(`${tag}: pack: the bank wants to confirm, nothing added`, (await p.page.locator("#zgc-status").innerText()) === "Your bank wants to confirm this payment");
      await shot(p.page, look, width, "pack-action", axeSource);
      await p.page.click("button:has-text('Confirm with your bank')");
      await p.page.waitForSelector(".zgc-standin", { timeout: 10000 }).catch(() => {});
      await p.page.click(".zgc-pay-foot button:has-text('Pay $29')");
      await p.page.waitForSelector(".zgc.is-confirmed", { timeout: 15000 }).catch(() => {});
      await p.page.waitForTimeout(4200);
      check(`${tag}: pack: added only when the server grants it`, (await p.page.locator("#zgc-status").innerText()) === "Pack added");
      await shot(p.page, look, width, "pack-added", axeSource);
      await p.ctx.close();

      // ---- no card saved ----
      const n = await open(browser, look, width.viewport, `/pay?business=${BIZ}&scenario=nocard`);
      await n.page.waitForSelector(".zpay-row", { timeout: 10000 }).catch(() => {});
      await n.page.click(".zpay-row:has-text('100 AI minutes') button:has-text('Buy')");
      await n.page.waitForSelector(".zgc", { timeout: 10000 }).catch(() => {});
      await n.page.click(".zgc-pay-foot button:has-text('Pay $29')");
      await n.page.waitForSelector(".zgc.is-error", { timeout: 10000 }).catch(() => {});
      check(`${tag}: no card: says so and offers Update card`, (await n.page.locator("#zgc-status").innerText()) === "There's no card to charge" && await n.page.isVisible(".zgc-pay-foot button:has-text('Update card')"));
      await shot(n.page, look, width, "no-card", axeSource);
      await n.ctx.close();
    }
  }

  // the emailed link: someone who isn't this invoice's owner gets nothing but "couldn't open"
  {
    const x = await open(browser, LOOKS[0], { width: 1440, height: 900 }, `/pay/invoice/00000000-0000-4000-8000-00000000ffff?scenario=`);
    await x.page.waitForTimeout(600);
    check("emailed link: an id that isn't this owner's opens nothing", await x.page.isVisible("text=We couldn't open this invoice") && (await x.page.locator(".zgc").count()) === 0);
    await x.ctx.close();
  }

  if (process.env.VIDEO) {
    fs.mkdirSync(process.env.VIDEO, { recursive: true });
    const v = await open(browser, LOOKS[0], { width: 1440, height: 900 }, `/pay?business=${BIZ}&scenario=`, { video: process.env.VIDEO });
    await v.page.waitForSelector(".zpay-row", { timeout: 10000 }).catch(() => {});
    await v.page.waitForTimeout(800);
    await v.page.click(".zpay-row:has-text('ZV-0042') button:has-text('Pay now')");
    await v.page.waitForTimeout(1000);
    await v.page.hover(".zgc-cardcol .zgc-card"); await v.page.mouse.move(400, 420, { steps: 12 }); await v.page.waitForTimeout(500);
    await v.page.click(".zgc-pay button:has-text('Pay now')");
    await v.page.waitForSelector(".zgc-standin", { timeout: 10000 }).catch(() => {});
    await v.page.waitForTimeout(1200);
    await v.page.click(".zgc-pay-foot button:has-text('Pay $249')");
    await v.page.waitForSelector(".zgc.is-confirmed", { timeout: 15000 }).catch(() => {});
    await v.page.waitForTimeout(4500);
    const rec = v.page.video();
    await v.ctx.close();
    const to = path.join(process.env.VIDEO, "crm-paynow-zella-1440.webm");
    fs.renameSync(await rec.path(), to);
    console.log(`video ${to}`);
  }
  await browser.close();
  console.log(`${passes} passed, ${fails} failed`);
  process.exit(fails ? 1 : 0);
})();
