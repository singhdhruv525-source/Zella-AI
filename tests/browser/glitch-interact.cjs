// Interaction sweep: on every page from a glitch-sweep run (tests/browser/glitch-sweep.cjs results.json), click each
// button that opens something (Add / New / Create / Edit / Filter / More / Open / Block / Book / Invite…), and check
// that a dialog, drawer, menu or form appears, that nothing crashes, no backend call fails and the console stays
// clean, and that Escape (or the close button) closes it again. ISOLATED test backend only; buttons that delete,
// cancel, send, call, sign out or pay are never clicked.
//
// Usage: node tests/browser/glitch-interact.cjs <persona> <results.json> [--mobile]
//   env APP_URL, BACKEND_URL, PERSONAS (as glitch-sweep.cjs), OUT
const { chromium } = require("playwright");
const fs = require("fs");
const path = require("path");

const APP = process.env.APP_URL ?? "http://localhost:5199";
const BACKEND = process.env.BACKEND_URL ?? "http://localhost:54321";
const OUT = process.env.OUT ?? path.join(__dirname, "out", "glitch");
const [persona, resultsFile] = process.argv.slice(2);
// Never against a real project: the backend must be the local stand-in on this machine.
{
  const host = new URL(BACKEND).hostname;
  if (!["localhost", "127.0.0.1", "::1", "[::1]"].includes(host)) { console.error(`Refusing to run: BACKEND_URL must be the local stand-in, not ${host}`); process.exit(2); }
}

const MOBILE = process.argv.includes("--mobile");
const PERSONAS = process.env.PERSONAS ? JSON.parse(process.env.PERSONAS) : {
  admin: "admin@zella.test", readonly: "readonly@zella.test",
  owner: "own-a@b3.test", manager: "multi@b3.test", staff: "staff-a@b3.test", viewer: "view-a@b3.test",
};
const OPENERS = /^(\+\s*)?(add|new|create|edit|filter|more|open|block time|book|invite|change|customize|manage|view|details|assign|move|reschedule|set up|choose|pick|upload|write|compose|reply|note|ask)\b/i;
const NEVER = /invite|import|connect|delete|remove|cancel|archive|send|call now|call |sign out|log out|pay|charge|refund|suspend|reactivate|publish|disconnect|revoke|reset|merge|block caller|mark |approve|decline|confirm|save|finish|submit|test ai voice|try again|refresh|export|download/i;

async function main() {
  const rows = JSON.parse(fs.readFileSync(resultsFile, "utf8"));
  const browser = await chromium.launch();
  const vw = MOBILE ? { width: 390, height: 844 } : { width: 1280, height: 860 };
  const ctx = await browser.newContext({ viewport: vw, reducedMotion: "reduce", isMobile: MOBILE, hasTouch: MOBILE });
  await ctx.route("https://zlocal.supabase.co/**", async (route) => {
    const req = route.request();
    try {
      const r = await fetch(req.url().replace("https://zlocal.supabase.co", BACKEND), { method: req.method(), headers: req.headers(), body: ["GET", "HEAD"].includes(req.method()) ? undefined : req.postDataBuffer() });
      await route.fulfill({ status: r.status, headers: Object.fromEntries(r.headers.entries()), body: Buffer.from(await r.arrayBuffer()) });
    } catch { await route.abort(); }
  });
  // every other outside address, http or https, answers empty: nothing leaves this machine but the font
  await ctx.route(/^https?:\/\/(?!zlocal\.supabase\.co[/:]|fonts\.googleapis\.com\/|fonts\.gstatic\.com\/|localhost[/:]|127\.0\.0\.1[/:])/, (r) => r.fulfill({ status: 200, body: "" }));
  const page = await ctx.newPage();
  page.setDefaultTimeout(5000);
  const errs = [], failed = [], cons = [];
  page.on("pageerror", (e) => errs.push(e.message.slice(0, 200)));
  page.on("console", (m) => { if (m.type() === "error" && !/Failed to load resource/.test(m.text())) cons.push(m.text().slice(0, 200)); });
  page.on("response", async (r) => {
    if (r.status() >= 400 && r.url().includes("zlocal.supabase.co")) {
      let body = ""; try { body = (await r.text()).slice(0, 160); } catch { /* */ }
      failed.push(`${r.status()} ${decodeURIComponent(r.url().replace(/^https?:\/\/[^/]+/, "")).split("?")[0]} ${body}`);
    }
  });
  const email = PERSONAS[persona];
  const root = /@b3\.test$/.test(email) ? "/app" : "/";
  await page.goto(APP + root);
  await page.fill('input[type="email"]', email);
  if (!(await page.$('input[type="password"]'))) await page.click('button[type="submit"]');
  await page.fill('input[type="password"]', "Test-pass-1");
  await page.click('button[type="submit"]');
  await page.waitForTimeout(3000);
  const report = [];
  for (const row of rows) {
    if (row.notAvailable || row.notFound) continue;
    await page.goto(APP + row.route).catch(() => {});
    await page.waitForTimeout(1800);
    // the visible words of a control, without the icon's ligature name ("event New visit" -> "New visit")
    const SEL = "main button, main a.ba-btn, .owner-content button, .ba-main button";
    const labels = await page.$$eval(SEL, (els) => [...new Set(els.filter((e) => e.offsetParent && !e.disabled && !e.closest("[role=dialog], .zs-tree, nav")).map((e) => {
      const c = e.cloneNode(true); c.querySelectorAll(".ba-icon, .material-symbols-rounded, [aria-hidden=true]").forEach((i) => i.remove());
      return (c.innerText || c.textContent || e.getAttribute("aria-label") || "").trim().replace(/\s+/g, " ");
    }).filter(Boolean))]).catch(() => []);
    for (const label of labels.filter((l) => OPENERS.test(l) && !NEVER.test(l)).slice(0, 8)) {
      errs.length = 0; failed.length = 0; cons.length = 0;
      const before = page.url();
      // click the control whose label is exactly the approved one (never a longer label that merely contains it,
      // such as "Add and send" for "Add"): it is marked in the page and clicked by that mark
      const marked = await page.evaluate(({ sel, label }) => {
        document.querySelectorAll("[data-glitch-target]").forEach((e) => e.removeAttribute("data-glitch-target"));
        const el = [...document.querySelectorAll(sel)].find((e) => {
          if (!e.offsetParent || e.disabled || e.closest("[role=dialog], .zs-tree, nav")) return false;
          const c = e.cloneNode(true); c.querySelectorAll(".ba-icon, .material-symbols-rounded, [aria-hidden=true]").forEach((i) => i.remove());
          return (c.innerText || c.textContent || e.getAttribute("aria-label") || "").trim().replace(/\s+/g, " ") === label;
        });
        if (el) el.setAttribute("data-glitch-target", "1");
        return Boolean(el);
      }, { sel: SEL, label }).catch(() => false);
      if (!marked) { report.push({ route: row.route, label, problem: "not found again" }); continue; }
      try { await page.locator("[data-glitch-target]").first().click({ timeout: 3000 }); } catch (e) { report.push({ route: row.route, label, problem: `could not click: ${e.message.split("\n")[0].slice(0, 120)}` }); continue; }
      await page.waitForTimeout(900);
      const state = await page.evaluate(() => {
        const dlg = document.querySelector('[role="dialog"], [role="menu"], .ba-modal, .owner-modal, .ba-drawer, .zs-drawer, [aria-modal="true"]');
        const r = dlg?.getBoundingClientRect();
        return {
          opened: Boolean(dlg),
          offscreen: r ? (r.left < -1 || r.top < -1 || r.right > innerWidth + 1 || r.bottom > innerHeight + 40) : false,
          dialogOverflowX: dlg ? dlg.scrollWidth - dlg.clientWidth : 0,
          crashed: /Something went wrong/i.test(document.body.innerText),
          raw: (dlg?.innerText.match(/\b(undefined|NaN|\[object Object\]|Invalid Date)\b/g) ?? []).join(","),
          focusInside: dlg ? dlg.contains(document.activeElement) : null,
        };
      }).catch(() => ({}));
      const navigated = page.url() !== before;
      const problems = [
        state.crashed && "CRASH", errs.length && `pageerror: ${errs[0]}`, failed.length && `failed: ${failed.slice(0, 2).join(" ; ")}`,
        cons.length && `console: ${cons[0]}`, state.offscreen && "dialog off screen", state.dialogOverflowX > 2 && `dialog sideways overflow ${state.dialogOverflowX}px`,
        state.raw && `raw values: ${state.raw}`, state.opened && state.focusInside === false && "focus not moved into dialog",
        !state.opened && !navigated && "nothing opened",
      ].filter(Boolean);
      if (state.opened) {
        await page.keyboard.press("Escape").catch(() => {});
        await page.waitForTimeout(400);
        const still = await page.$('[role="dialog"], [role="menu"], .ba-modal, .owner-modal, .ba-drawer, .zs-drawer, [aria-modal="true"]');
        if (still && (await still.isVisible().catch(() => false))) {
          problems.push("Escape doesn't close it");
          const close = page.locator('[role="dialog"] button[aria-label*="Close" i], [role="dialog"] button:has-text("Close"), [role="dialog"] button:has-text("Cancel"), .ba-modal button:has-text("Cancel")').first();
          if (await close.count()) await close.click().catch(() => {});
          await page.waitForTimeout(300);
        }
      }
      if (navigated) await page.goto(APP + row.route).catch(() => {}), await page.waitForTimeout(1200);
      report.push({ route: row.route, label, opened: state.opened, navigated, problems });
      console.log(`${problems.length ? "CHECK" : "ok   "} ${persona} ${row.route} «${label}» ${problems.join(" | ")}`);
    }
  }
  fs.mkdirSync(OUT, { recursive: true });
  fs.writeFileSync(path.join(OUT, `interact-${persona}${MOBILE ? "-mobile" : ""}.json`), JSON.stringify(report, null, 1));
  console.log(`DONE ${report.length} clicks, ${report.filter((r) => r.problems?.length).length} to look at`);
  await browser.close();
}
main();
