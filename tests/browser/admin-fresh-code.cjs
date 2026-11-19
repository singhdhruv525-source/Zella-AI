// ACC-19: adding an admin or changing admin access needs an authenticator code entered in the last 5 minutes, in a
// real browser against the local stand in over an ISOLATED test database. The stand in signs in with a password
// only (ZTEST_PASSWORD_AAL2=1 gives aal2 without a code time), so the first change is refused and asks for a code.
// Desktop (1440x900) and phone (390 wide). Nothing is sent: the stand in records the invitation only.
// Needs: the stand in PROCESS (local-backend.mjs, not this journey) started with ZTEST_PASSWORD_AAL2=1, and the test
// owner (admin@zella.test) with a verified authenticator in auth.mfa_factors.
// Usage: ZDB=<test db> APP_URL=... BACKEND_URL=... SHOTS=<folder> node tests/browser/admin-fresh-code.cjs
const path = require("path");
const k = require("./real-kit.cjs");
const SHOTS = process.env.SHOTS ?? path.join(__dirname, "out", "admin-fresh-code");
const OWNER = "admin@zella.test";

(async () => {
  k.guard();
  require("fs").mkdirSync(SHOTS, { recursive: true });
  const stamp = Date.now().toString(36);

  // the server, with a session whose code is not fresh
  const tok = await k.token(OWNER);
  const direct = `direct-${stamp}@lanea.test`;
  const r = await k.fn(tok, { action: "admin_invite", email: direct, role: "support_admin" });
  k.check("the server refuses adding an admin without a fresh code (FRESH_CODE_REQUIRED)", r.status === 403 && r.body.code === "FRESH_CODE_REQUIRED", `${r.status} ${r.body.code ?? r.body.error}`);
  k.check("and nothing was created", k.sql(`select count(*) from auth.users where email = '${direct}'`) === "0");
  const list = await k.fn(tok, { action: "admins_list" });
  k.check("reading the admin list needs no fresh code", list.status === 200);

  const browser = await k.chromium.launch();
  for (const [width, tag] of [[1440, "desktop"], [390, "phone"]]) {
    const email = `fresh-${tag}-${stamp}@lanea.test`;
    const ctx = await k.context(browser, width);
    const p = await k.page(ctx);
    await k.signIn(p, OWNER);
    await p.goto(k.APP + "/users");
    await p.click('button:has-text("Add admin")');
    await p.fill('input[type="email"]', email);
    await p.selectOption("form.wiz-section select", "support_admin");
    await p.click('form.wiz-section button[type="submit"]');
    const form = p.locator('form[aria-label="Confirm with your authenticator"]');
    await form.waitFor();
    k.check(`${tag}: adding an admin asks for a new authenticator code`, true);
    k.check(`${tag}: nothing is created before the code`, k.sql(`select count(*) from auth.users where email = '${email}'`) === "0");
    await p.waitForTimeout(800); await p.screenshot({ path: path.join(SHOTS, `fresh-code-asked-${tag}.png`) });
    await k.freshCode(p, "000000");
    await p.waitForSelector("text=That code didn't work");
    k.check(`${tag}: a wrong code is refused and the prompt stays`, await form.isVisible());
    await k.freshCode(p, "123456");
    await p.waitForSelector(`text=Invitation emailed to ${email}`);
    k.check(`${tag}: with the code, the same change goes through`, k.sql(`select count(*) from public.platform_admins a join auth.users u on u.id = a.user_id where u.email = '${email}' and a.role = 'support_admin'`) === "1");
    k.check(`${tag}: and is audited as admin.added`, k.sql(`select count(*) from public.audit_logs a join auth.users u on u.id::text = a.entity_id::text where u.email = '${email}' and a.action = 'admin.added'`) === "1");
    await p.waitForTimeout(800); await p.screenshot({ path: path.join(SHOTS, `fresh-code-done-${tag}.png`) });
    // within 5 minutes of the code, the next change isn't asked again
    const target = `select a.user_id from public.platform_admins a join auth.users u on u.id = a.user_id where u.email = '${email}'`;
    await p.locator(`select[aria-label="Role for ${email}"]`).selectOption("billing_admin");
    await p.click('button:has-text("Change role")');
    const askedAgain = await k.freshCode(p);
    await p.waitForSelector(`text=${email} is now a Billing admin`);
    k.check(`${tag}: a second change within 5 minutes needs no new code`, !askedAgain && k.sql(`select role from public.platform_admins where user_id = (${target})`) === "billing_admin");
    k.check(`${tag}: no page errors`, p.errors.length === 0, p.errors.join(" | "));
    k.sql(`update public.platform_admins set is_active = false where user_id = (${target})`);
    await ctx.close();
  }
  await browser.close();
  console.log(k.failures() ? `${k.failures()} FAILED` : "ALL PASSED");
  process.exit(k.failures() ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
