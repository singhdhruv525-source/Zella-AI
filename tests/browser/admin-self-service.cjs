// ACC-30: an admin's own authenticator and password changes go through owner-provision-business, are audited, and
// keep at least one authenticator; in a real browser against the local stand in over an ISOLATED test database.
// Desktop (1440x900) and phone (390 wide). Nothing is sent.
// Needs: the stand in process (local-backend.mjs) started with ZTEST_PASSWORD_AAL2=1, and the test admin with a verified
// authenticator, so a password sign in passes two step sign in but carries no recent code time (the stale code check
// then reaches FRESH_CODE_REQUIRED). The stand in records a password change as a time only (every test password stays
// Test-pass-1), so the password part checks that the change is submitted, accepted and audited, not a later sign in.
// Usage: ZDB=<test db> APP_URL=... BACKEND_URL=... SHOTS=<folder> node tests/browser/admin-self-service.cjs
const path = require("path");
const k = require("./real-kit.cjs");
const SHOTS = process.env.SHOTS ?? path.join(__dirname, "out", "admin-self-service");
const ADMIN = "admin@zella.test", MEMBER = "own-a@b3.test";
const uid = () => k.sql(`select id from auth.users where email = '${ADMIN}'`);
const factors = () => Number(k.sql(`select count(*) from auth.mfa_factors where user_id = '${uid()}' and status = 'verified'`));
const audits = (action) => Number(k.sql(`select count(*) from public.audit_logs where user_id = '${uid()}' and action = '${action}'`));
const secondFactor = () => k.sql(`insert into auth.mfa_factors (id, user_id, factor_type, status, friendly_name) values (gen_random_uuid(), '${uid()}', 'totp', 'verified', 'Old phone')`);

(async () => {
  k.guard();
  require("fs").mkdirSync(SHOTS, { recursive: true });
  // keep exactly one authenticator to start
  k.sql(`delete from auth.mfa_factors where user_id = '${uid()}' and id <> (select id from auth.mfa_factors where user_id = '${uid()}' and status = 'verified' order by created_at limit 1)`);

  // the server
  let r = await k.fn(null, { action: "me_password_change", password: "Newpass123" });
  k.check("anonymous is refused", r.status === 401, String(r.status));
  r = await k.fn(await k.token(MEMBER), { action: "me_password_change", password: "Newpass123" });
  k.check("a business member is refused (not a platform admin)", r.status === 403, `${r.status} ${r.body.error}`);
  r = await k.fn(await k.token(ADMIN), { action: "me_password_change", password: "Newpass123" });
  k.check("an admin without a fresh code is refused (FRESH_CODE_REQUIRED)", r.status === 403 && r.body.code === "FRESH_CODE_REQUIRED", `${r.status} ${r.body.code}`);
  const fresh = await k.freshToken(ADMIN);
  const only = k.sql(`select id from auth.mfa_factors where user_id = '${uid()}' and status = 'verified' limit 1`);
  r = await k.fn(fresh, { action: "me_mfa_remove", factorId: only });
  k.check("the server refuses removing the last authenticator", r.status === 409 && factors() === 1, `${r.status} ${r.body.error}`);
  r = await k.fn(fresh, { action: "me_password_change", password: "short" });
  k.check("the server checks the password rule", r.status === 400, `${r.status} ${r.body.error}`);
  r = await k.fn(fresh, { action: "me_mfa_added", factorId: "11111111-1111-1111-1111-111111111111" });
  k.check("a made up authenticator isn't recorded", r.status === 404, String(r.status));

  const browser = await k.chromium.launch();
  // business settings: the card asks the database whether this is an admin; until it knows, or when it can't tell,
  // Remove is not offered (an admin would need the code field), and a failed check can be tried again
  const MEMBER_FACTOR = "f5500000-0000-0000-0000-000000000001";
  const memberId = k.sql(`select id from auth.users where email = '${MEMBER}'`);
  k.sql(`insert into auth.mfa_factors (id, user_id, factor_type, status, friendly_name) values ('${MEMBER_FACTOR}', '${memberId}', 'totp', 'verified', 'Member phone') on conflict (id) do nothing`);
  try {
    const ctx = await k.context(browser, 1440);
    const p = await k.page(ctx);
    await k.signIn(p, MEMBER);
    let release; const held = new Promise((r) => { release = r; });
    await p.route("**/rest/v1/rpc/zella_admin_role", async (route) => { await held; await route.fulfill({ status: 500, contentType: "application/json", body: '{"message":"test failure"}' }); });
    await p.goto(k.APP + "/app/settings/me/security");
    const remove = p.locator(".zs-savebar", { hasText: "Member phone" }).locator('button:has-text("Remove")');
    await remove.waitFor();
    k.check("business settings: while the account check is pending, Remove is not offered", await remove.isDisabled());
    release();
    await p.waitForSelector("text=couldn't be checked, so authenticators can't be removed");
    k.check("business settings: when the account check fails, Remove stays off and the page says so", await remove.isDisabled());
    await p.unroute("**/rest/v1/rpc/zella_admin_role");
    await p.locator('.zs-banner, [role="alert"]', { hasText: "couldn't be checked" }).locator('button:has-text("Try again")').click();
    await p.waitForFunction(() => [...document.querySelectorAll(".zs-savebar")].some((b) => b.textContent.includes("Member phone") && b.querySelector("button.danger-outline:not([disabled])")));
    k.check("business settings: after Try again, a business member can remove it", await remove.isEnabled() && !(await p.isVisible("text=couldn't be checked")));
    k.check("business settings: no page errors", p.errors.length === 0, p.errors.join(" | "));
    await ctx.close();
  } finally {
    k.sql(`delete from auth.mfa_factors where id = '${MEMBER_FACTOR}'`);
  }
  for (const [width, tag] of [[1440, "desktop"], [390, "phone"]]) {
    const ctx = await k.context(browser, width);
    const p = await k.page(ctx);
    await k.signIn(p, ADMIN);
    secondFactor();
    await p.goto(k.APP + "/settings/profile/security");
    await p.waitForSelector("text=Old phone");
    // remove one of two, with a new code
    const removed = audits("admin.mfa_removed");
    await p.locator(".zs-savebar", { hasText: "Old phone" }).locator('button:has-text("Remove")').click();
    await p.waitForSelector(".zs-dialog");
    await p.fill('.zs-dialog input[autocomplete="one-time-code"]', "123456");
    await p.waitForTimeout(500); await p.screenshot({ path: path.join(SHOTS, `remove-confirm-${tag}.png`) });
    await p.click('.zs-dialog button:has-text("Remove")');
    await p.waitForSelector(".zs-dialog", { state: "detached" });
    const survivor = k.sql(`select coalesce(string_agg(id::text, ','), '') from auth.mfa_factors where user_id = '${uid()}' and status = 'verified'`);
    k.check(`${tag}: removing one of two authenticators works, keeps the original one and is audited`, factors() === 1 && survivor === only && audits("admin.mfa_removed") === removed + 1, `${factors()} left (${survivor}, original ${only}), audit ${audits("admin.mfa_removed")}`);
    const last = p.locator(".zs-savebar", { hasText: "Required for admins" });
    await last.waitFor();
    k.check(`${tag}: the last one shows Required for admins and has no Remove button`, (await last.locator('button:has-text("Remove")').count()) === 0
      && (await p.locator(".zs-savebar .zs-btn.danger-outline").count()) === 0);
    // add another one
    const added = audits("admin.mfa_added");
    await p.click('button:has-text("Add another authenticator app")');
    await p.getByLabel("Code from the app").fill("123456");
    await p.click('button:has-text("Turn on")');
    // the list refreshes to two authenticators, each with Remove; a timeout here fails the journey
    await p.waitForFunction(() => document.querySelectorAll(".zs-savebar .zs-btn.danger-outline").length === 2, null, { timeout: 15000 });
    k.check(`${tag}: a new authenticator is recorded in the audit log`, factors() === 2 && audits("admin.mfa_added") === added + 1, `${factors()} factors, audit ${audits("admin.mfa_added")}`);
    // password, with a new code
    const changed = audits("admin.password_changed");
    await p.fill('input[autocomplete="new-password"] >> nth=0', "Newpass123");
    await p.fill('input[autocomplete="new-password"] >> nth=1', "Newpass123");
    await p.getByLabel("Code from your authenticator app").fill("123456");
    await p.waitForTimeout(400); await p.screenshot({ path: path.join(SHOTS, `password-${tag}.png`) });
    await p.click('button:has-text("Change password")');
    await p.waitForSelector("text=Password changed.");
    k.check(`${tag}: an admin's password change is submitted through the server, accepted and audited`, audits("admin.password_changed") === changed + 1);
    const leak = k.sql(`select count(*) from public.audit_logs where (coalesce(new_data::text, '') || coalesce(old_data::text, '')) like '%Newpass123%'`);
    k.check(`${tag}: the password never reaches the audit log`, leak === "0");
    await p.waitForTimeout(600); await p.screenshot({ path: path.join(SHOTS, `security-done-${tag}.png`), fullPage: true });
    k.check(`${tag}: no page errors`, p.errors.length === 0, p.errors.join(" | "));
    k.sql(`delete from auth.mfa_factors where user_id = '${uid()}' and id <> (select id from auth.mfa_factors where user_id = '${uid()}' and status = 'verified' order by created_at limit 1)`);
    await ctx.close();
  }
  await browser.close();
  console.log(k.failures() ? `${k.failures()} FAILED` : "ALL PASSED");
  process.exit(k.failures() ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
