// The owner onboarding journey (/welcome/setup) in a real browser, every screen from Welcome to You're all set, against
// the stand in api (web/src/onboarding/fakeApi.js), which answers in the shapes and with the rules of
// docs/OWNER_ONBOARDING_CONTRACT.md. Nothing reaches Supabase: every request to the project address is refused here
// and counted. Nothing is sent. The stand in's only working authenticator code is 123456.
//
// Build and serve a LOCAL copy with the stand in switched on (never a production build):
//   cd web && VITE_ONBOARDING_FAKE=1 VITE_SUPABASE_URL=https://zlocal.supabase.co \
//     VITE_SUPABASE_PUBLISHABLE_KEY=sb_publishable_local_test_only npx vite build --outDir /tmp/zella-onb
//   npx vite preview --outDir /tmp/zella-onb --port 5180 --strictPort
// Then: APP_URL=http://localhost:5180 SHOTS=<folder> node tests/browser/owner-onboarding-journey.cjs
// Screenshots: each screen at 390 wide and at 1440x900, in the Classic look and the Glass (dark) look.
const { chromium } = require("playwright");
const fs = require("fs");
const path = require("path");
const APP = process.env.APP_URL ?? "http://localhost:5180";
const SHOTS = process.env.SHOTS ?? path.join(process.cwd(), "onb-shots");
if (!["localhost", "127.0.0.1"].includes(new URL(APP).hostname)) { console.error("APP_URL must be a local preview"); process.exit(2); }
fs.mkdirSync(SHOTS, { recursive: true });

let fails = 0;
const check = (name, ok, detail = "") => { console.log(`${ok ? "PASS" : "FAIL"} ${name}${detail ? " - " + detail : ""}`); if (!ok) fails++; };
const VARIANTS = [
  { name: "phone-light", viewport: { width: 390, height: 844 }, glass: false },
  { name: "phone-dark", viewport: { width: 390, height: 844 }, glass: true },
  { name: "desktop-light", viewport: { width: 1440, height: 900 }, glass: false },
  { name: "desktop-dark", viewport: { width: 1440, height: 900 }, glass: true },
];
const PDF = { name: "document.pdf", mimeType: "application/pdf", buffer: Buffer.from("%PDF-1.4\n% test file\n") };

async function newPage(browser, variant, supabaseHits) {
  const ctx = await browser.newContext({ viewport: variant.viewport, deviceScaleFactor: 1 });
  await ctx.route((url) => ["http:", "https:"].includes(url.protocol), async (route) => {
    const url = new URL(route.request().url());
    if (["localhost", "127.0.0.1", "fonts.googleapis.com", "fonts.gstatic.com"].includes(url.hostname)) return route.continue();
    if (url.hostname.endsWith("supabase.co")) supabaseHits.push(`${route.request().method()} ${url.pathname}`);
    return route.fulfill({ status: 503, contentType: "application/json", body: "{}" });
  });
  if (variant.glass) {
    await ctx.addInitScript(() => {
      try { localStorage.setItem("zella.appearance.crm", JSON.stringify({ user: null, pref: { theme: "glass", background: "plain", dim: 35, matchPicture: false } })); } catch { /* none */ }
    });
  }
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  return { ctx, page, errors };
}

const heading = (page) => page.evaluate(() => { const a = document.activeElement; return a && /^H[12]$/.test(a.tagName) ? a.textContent.trim() : `(focus on ${a?.tagName})`; });
const progress = (page) => page.getAttribute('[role="progressbar"]', "aria-valuenow").catch(() => null);
const hook = (page, name, ...args) => page.evaluate(([n, a]) => window.__zellaOnboardingFake[n](...a), [name, args]);
const overflow = (page) => page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth + 1);
async function waitHeading(page, text) {
  await page.waitForFunction((t) => [...document.querySelectorAll("h1")].some((h) => h.textContent.includes(t)), text, { timeout: 10000 }).catch(() => {});
  await page.waitForTimeout(150);
}

async function journey(browser, variant) {
  const hits = [];
  const { ctx, page, errors } = await newPage(browser, variant, hits);
  const v = variant.name;
  const full = variant.viewport.width >= 1000;
  let n = 0;
  const shot = async (label) => { n++; await page.screenshot({ path: path.join(SHOTS, `${String(n).padStart(2, "0")}-${label}-${v}.png`), fullPage: true }); };
  const main = v === "phone-light";   // the detailed checks run once; the other looks repeat the walk for screenshots

  await page.goto(`${APP}/welcome/setup`);
  await page.evaluate(() => localStorage.removeItem("zella.onboardingFake.v2"));
  await page.reload();

  // 1 Welcome
  await waitHeading(page, "Welcome to Zella Voice, Maple Street Salon");
  if (main) {
    check("1 Welcome: the business name, with focus on the heading", (await heading(page)) === "Welcome to Zella Voice, Maple Street Salon", await heading(page));
    check("1 Welcome: the progress bar says step 1 of 7", (await progress(page)) === "1" && await page.isVisible("text=Step 1 of 7"));
    check("1 Welcome: the steps ahead are listed", await page.isVisible("text=The steps ahead") && await page.isVisible(".zob-ahead >> text=Verify your identity"));
    check("1 Welcome: Finish later is offered", await page.isVisible("button:has-text('Finish later')"));
  }
  if (variant.glass) check(`${v}: the Glass look is on`, await page.evaluate(() => document.documentElement.dataset.zellaTheme === "glass"));
  await shot("welcome");
  await page.click("button:has-text('Get started')");

  // 2 Password and two step sign in
  await waitHeading(page, "Password and two step sign in");
  if (main) {
    check("2 Security: focus moves to the new heading", (await heading(page)) === "Password and two step sign in", await heading(page));
    check("2 Security: step 2 of 7", (await progress(page)) === "2");
    await page.click("button:has-text('Save password and continue')");
    check("2 Security: an empty password is refused in words", await page.isVisible(".ba-error"));
  }
  await shot("password");
  await page.fill("#zob-password", "Good pass 1234");
  await page.fill("#zob-password2", "Good pass 1234");
  await page.click("button:has-text('Save password and continue')");
  await page.waitForSelector('img[alt^="QR code"]', { timeout: 10000 }).catch(() => {});
  if (main) {
    check("2 Security: then the authenticator, with a code to scan and the key", await page.isVisible('img[alt^="QR code"]') && await page.isVisible("text=TESTSECRET123456"));
    await page.fill(".zv-authsetup input", "000000");
    await page.click("button:has-text('Turn on and continue')");
    await page.waitForSelector(".zv-authsetup-error", { timeout: 5000 }).catch(() => {});
    check("2 Security: a wrong code is refused with a message", await page.isVisible(".zv-authsetup-error"));
  }
  await shot("authenticator");
  await page.fill(".zv-authsetup input", "123456");
  await page.click("button:has-text('Turn on and continue')");
  await page.waitForSelector("text=Your password and two step sign in are set up.", { timeout: 10000 }).catch(() => {});
  if (main) check("2 Security: the right code turns it on", await page.isVisible("text=Your password and two step sign in are set up."));
  await page.click(".zob-actions button:has-text('Continue')");

  // 3 Check your details
  await waitHeading(page, "Check your details");
  if (main) {
    check("3 Details: focus on the heading, step 3 of 7", (await heading(page)) === "Check your details" && (await progress(page)) === "3", await heading(page));
    check("3 Details: the business section first, with what the admin entered", await page.isVisible(".zob-section h2:has-text('Your business')") && await page.isVisible("text=(555) 010 2040"));
    check("3 Details: Continue waits until every part is confirmed", await page.isDisabled(".zob-actions button:has-text('Continue')"));
  }
  await shot("details-business");
  await page.click(".zob-section-actions button:has-text('Looks right')");
  await page.waitForSelector(".zob-section h2:has-text('Hours and services')", { timeout: 5000 }).catch(() => {});
  if (main) check("3 Details: Looks right moves to the next part, and focus goes to its name", (await heading(page)) === "Hours and services", await heading(page));
  await page.click(".zob-section-actions button:has-text('Change')");
  await page.fill(".zob-section textarea", "We close at 18:00 on Fridays.");
  await shot("details-change-note");
  await page.click("button:has-text('Send to the Zella Voice team')");
  await page.waitForSelector(".zob-section h2:has-text('Your team')", { timeout: 5000 }).catch(() => {});
  await page.click(".zob-section-actions button:has-text('Looks right')");
  await page.waitForSelector(".zob-section h2:has-text('AI receptionist and phone')", { timeout: 5000 }).catch(() => {});
  await shot("details-receptionist");
  await page.click(".zob-section-actions button:has-text('Looks right')");
  await page.waitForTimeout(400);
  if (main) {
    await page.click(".zob-section-tab:has-text('Hours and services')");
    check("3 Details: a change request waits for Zella Voice and keeps the owner's note", await page.isVisible(".zob-chip:has-text('Waiting for Zella Voice')") && await page.isVisible("text=We close at 18:00 on Fridays."));
    check("3 Details: and the step can't be finished yet", await page.isDisabled(".zob-actions button:has-text('Continue')"));
  }
  await shot("details-waiting");

  // Finish later, then come back
  await page.click("button:has-text('Finish later')");
  await waitHeading(page, "Your place is saved");
  if (main) check("Finish later: says the place is saved, with focus on the heading", (await heading(page)) === "Your place is saved", await heading(page));
  await shot("finish-later");
  // the Zella Voice team makes the change; the owner comes back on a new page load
  await hook(page, "adminChangeDone", "hours_services", "Changed to 18:00 on Fridays.");
  await page.reload();
  await waitHeading(page, "Check your details");
  if (main) check("Finish later: a new visit lands on the same step", (await heading(page)) === "Check your details" && (await progress(page)) === "3");
  await page.waitForSelector(".zob-section h2:has-text('Hours and services')", { timeout: 5000 }).catch(() => {});
  if (main) check("3 Details: the changed part comes back to check, with the team's note", await page.isVisible(".zob-chip:has-text('Changed, check again')") && await page.isVisible("text=Changed to 18:00 on Fridays."));
  await shot("details-changed");
  await page.click(".zob-section-actions button:has-text('Looks right')");
  await page.waitForSelector("text=Every part looks right.", { timeout: 5000 }).catch(() => {});
  await page.click(".zob-actions button:has-text('Continue')");

  // 4 Verify your identity
  await waitHeading(page, "Verify your identity");
  if (main) {
    check("4 Identity: focus on the heading, step 4 of 7", (await heading(page)) === "Verify your identity" && (await progress(page)) === "4", await heading(page));
    check("4 Identity: Documents needed, with both uploads offered", await page.isVisible(".zob-status >> text=Documents needed") && (await page.$$(".zob-upload input")).length === 2);
    check("4 Identity: no provider widget while the rule is manual upload", !(await page.$(".zob-provider")));
  }
  await shot("identity-needed");
  await page.setInputFiles('input[aria-label="Upload your photo id"]', PDF);
  await page.waitForTimeout(400);
  await page.setInputFiles('input[aria-label="Upload business registration"]', PDF);
  await page.waitForSelector(".zob-status >> text=Checking", { timeout: 5000 }).catch(() => {});
  if (main) check("4 Identity: after both uploads it says Checking, and Continue waits", await page.isVisible(".zob-status >> text=Checking") && await page.isDisabled(".zob-actions button:has-text('Continue')"));
  await shot("identity-checking");
  await hook(page, "rejectIdentity", "The photo is blurred.");
  await page.click("button:has-text('Check again')");
  await page.waitForSelector(".zob-status >> text=Try again", { timeout: 5000 }).catch(() => {});
  if (main) check("4 Identity: Try again, with the reason and a new upload for that document only", await page.isVisible("text=Why: The photo is blurred.") && (await page.$$(".zob-upload input")).length === 1);
  await shot("identity-try-again");
  await page.setInputFiles('input[aria-label="Upload a new copy of your photo id"]', PDF);
  await page.waitForSelector(".zob-status >> text=Checking", { timeout: 5000 }).catch(() => {});
  await hook(page, "approveIdentity");
  await page.click("button:has-text('Check again')");
  await page.waitForSelector(".zob-status >> text=Verified", { timeout: 5000 }).catch(() => {});
  if (main) check("4 Identity: Verified once the server says so", await page.isVisible(".zob-status >> text=Verified") && await page.isEnabled(".zob-actions button:has-text('Continue')"));
  await shot("identity-verified");
  await page.click(".zob-actions button:has-text('Continue')");

  // 5 Your plan
  await waitHeading(page, "Your plan");
  if (main) {
    check("5 Plan: focus on the heading, step 5 of 7", (await heading(page)) === "Your plan" && (await progress(page)) === "5", await heading(page));
    check("5 Plan: the plan as the admin set it", await page.isVisible(".zob-plan h2:has-text('Pro')") && await page.isVisible("text=$249") && await page.isVisible("text=1,000 minutes") && await page.isVisible("text=English and Spanish"));
    check("5 Plan: accept only, no switching", !(await page.isVisible("text=Base")) && await page.isVisible("button:has-text('Accept plan and continue')"));
  }
  await shot("plan");
  await page.click("button:has-text('Accept plan and continue')");

  // 6 Pay
  await waitHeading(page, "Pay for your plan");
  if (main) {
    check("6 Pay: focus on the heading, step 6 of 7", (await heading(page)) === "Pay for your plan" && (await progress(page)) === "6", await heading(page));
    check("6 Pay: a calm waiting screen, never a fake success", await page.isVisible("text=Payment opens here soon") && !(await page.isVisible("text=Payment received")) && !(await page.isVisible(".zob-actions button:has-text('Continue')")));
    await page.click(".zob-back");
    await waitHeading(page, "Your plan");
    check("Back: the plan again, marked accepted", await page.isVisible("text=You accepted this plan."));
    await page.click(".zob-actions button:has-text('Continue')");
    await waitHeading(page, "Pay for your plan");
  }
  await shot("pay-waiting");
  await hook(page, "confirmPayment");
  await page.click("button:has-text('Check again')");
  await page.waitForSelector("text=Payment received", { timeout: 5000 }).catch(() => {});
  if (main) check("6 Pay: Payment received only after the server confirms it", await page.isVisible("text=Payment received"));
  await shot("pay-received");
  await page.click(".zob-actions button:has-text('Continue')");

  // 7 You're all set
  await waitHeading(page, "You're all set");
  if (main) {
    check("7 Done: focus on the heading, step 7 of 7", (await heading(page)) === "You're all set" && (await progress(page)) === "7", await heading(page));
    check("7 Done: what happens next, and the go live checks", await page.isVisible("text=A test call") && await page.isVisible("text=Going live") && await page.isVisible(".zob-checks >> text=Test call answered"));
  }
  await shot("done");
  check(`${v}: never wider than the screen`, !(await overflow(page)));
  check(`${v}: nothing reached Supabase during the journey`, hits.length === 0, hits.join(", "));
  if (main) {
    const went = [];
    page.on("framenavigated", (f) => { if (f === page.mainFrame()) went.push(f.url()); });
    await page.click("button:has-text('Open my CRM')");
    await page.waitForURL(/\/app/, { timeout: 10000 }).catch(() => {});
    // the CRM takes ?business= out of the address once it has read it, so check where the button sent us
    check("7 Done: Open my CRM goes to the CRM for this business", went.some((u) => /\/app\?business=00000000-0000-4000-8000-0000000000b1/.test(u)), went.join(", "));
  }
  check(`${v}: no page errors`, errors.length === 0, errors.join("; "));
  await ctx.close();
}

async function scenario(browser, name, query, checks) {
  const hits = [];
  const { ctx, page, errors } = await newPage(browser, VARIANTS[0], hits);
  await page.goto(`${APP}/welcome/setup?scenario=${query}`);
  await page.evaluate(() => localStorage.removeItem("zella.onboardingFake.v2"));
  await page.reload();
  await page.waitForTimeout(900);
  await checks(page);
  await page.screenshot({ path: path.join(SHOTS, `state-${name}-phone-light.png`), fullPage: true });
  check(`${name}: no page errors`, errors.length === 0, errors.join("; "));
  await ctx.close();
}

(async () => {
  const browser = await chromium.launch();
  for (const variant of VARIANTS) await journey(browser, variant);

  await scenario(browser, "not-ready", "notready", async (page) => {
    check("not deployed: This step isn't ready yet, never a crash", await page.isVisible("text=This step isn't ready yet") && await page.isVisible("a:has-text('Open my CRM')"));
  });
  await scenario(browser, "load-failed", "flaky", async (page) => {
    check("a failed load says so in words, with Try again", await page.isVisible("text=We couldn't reach Zella Voice") && await page.isVisible("button:has-text('Try again')"));
    await page.click("button:has-text('Try again')");
    await page.waitForSelector("h1:has-text('Welcome to Zella Voice')", { timeout: 5000 }).catch(() => {});
    check("and the retry works", await page.isVisible("h1:has-text('Welcome to Zella Voice')"));
  });
  await scenario(browser, "nothing-waiting", "none", async (page) => {
    check("nothing waiting: says so, with the way to the CRM", await page.isVisible("h1:has-text('Nothing to set up here')"));
  });
  await scenario(browser, "upload-not-ready", "partial", async (page) => {
    // get to step 4 through the stand in, as the server would after steps 1 to 3
    await page.evaluate(async () => {
      const f = window.__zellaOnboardingFake; const id = "00000000-0000-4000-8000-0000000000b1";
      await f.completeStep(id, "welcome"); await f.setPassword("Good pass 1234"); await f.finishMfa("x", "123456"); await f.completeStep(id, "security");
      for (const k of ["business", "hours_services", "team", "receptionist_phone"]) await f.answerSection(id, k, "looks_right");
      await f.completeStep(id, "details");
    });
    await page.reload();
    await waitHeading(page, "Verify your identity");
    await page.setInputFiles('input[aria-label="Upload your photo id"]', PDF);
    await page.waitForSelector("text=Uploading isn't ready yet", { timeout: 5000 }).catch(() => {});
    check("upload not deployed: says it isn't ready yet, and nothing pretends it worked", await page.isVisible("text=Uploading isn't ready yet") && await page.isVisible(".zob-status >> text=Documents needed"));
  });
  await scenario(browser, "returning", "returning", async (page) => {
    await waitHeading(page, "Check your details");
    check("returning after Finish later: straight back to Check your details", await page.isVisible("h1:has-text('Check your details')") && (await progress(page)) === "3");
  });

  await browser.close();
  console.log(fails ? `${fails} FAILED` : "ALL PASSED");
  process.exit(fails ? 1 : 0);
})();
