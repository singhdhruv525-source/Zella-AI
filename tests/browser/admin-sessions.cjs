// ACC-18 and ACC-30 (sign out other devices) in a real browser against the local stand in over an ISOLATED test
// database with sql/zella_admin_sessions.sql applied. Desktop (1440x900) and phone (390 wide). Nothing is sent.
// Usage: ZDB=<test db> APP_URL=... BACKEND_URL=... SHOTS=<folder> node tests/browser/admin-sessions.cjs
const path = require("path");
const k = require("./real-kit.cjs");
const SHOTS = process.env.SHOTS ?? path.join(__dirname, "out", "admin-sessions");
const OWNER = "admin@zella.test", TARGET = "readonly@zella.test";
const id = (email) => k.sql(`select id from auth.users where email = '${email}'`);
const sessions = (uid, n) => k.sql(`insert into auth.sessions (user_id, aal) select '${uid}', 'aal2' from generate_series(1, ${n})`);
const count = (uid) => Number(k.sql(`select count(*) from auth.sessions where user_id = '${uid}'`));

(async () => {
  k.guard();
  require("fs").mkdirSync(SHOTS, { recursive: true });
  k.check("the test database has zella_end_user_sessions", k.sql("select to_regprocedure('public.zella_end_user_sessions(uuid)') is not null") === "t");
  const owner = id(OWNER), target = id(TARGET);
  const browser = await k.chromium.launch();
  for (const [width, tag] of [[1440, "desktop"], [390, "phone"]]) {
    k.sql(`update public.platform_admins set role = 'read_only_admin', is_active = true where user_id = '${target}'`);
    k.sql(`delete from auth.sessions where user_id in ('${owner}', '${target}')`);
    sessions(target, 2);
    const ctx = await k.context(browser, width);
    const p = await k.page(ctx);
    await k.signIn(p, OWNER);
    await p.goto(k.APP + "/users");
    const select = p.locator(`select[aria-label="Role for ${TARGET}"]`);
    await select.waitFor();
    await select.selectOption("support_admin");
    await p.waitForSelector("text=They will be signed out on every device.");
    k.check(`${tag}: changing a role warns they will be signed out on every device`, true);
    await p.waitForTimeout(800); await p.screenshot({ path: path.join(SHOTS, `users-confirm-${tag}.png`), fullPage: false });
    await p.click('button:has-text("Change role")');
    await p.waitForSelector("text=They were signed out on 2 devices.");
    k.check(`${tag}: after the change the page says 2 devices were signed out`, true);
    k.check(`${tag}: and the database has none of their sessions left`, count(target) === 0, `${count(target)} left`);
    const audit = k.sql(`select new_data ->> 'sessions_ended' from public.audit_logs where action = 'admin.updated' and entity_id = '${target}' order by created_at desc limit 1`);
    k.check(`${tag}: the admin.updated audit entry records sessions_ended`, audit === "2", audit);
    await p.waitForTimeout(800); await p.screenshot({ path: path.join(SHOTS, `users-done-${tag}.png`), fullPage: false });

    // sign out other devices, from the owner's own security settings
    sessions(owner, 2);
    const before = Number(k.sql(`select count(*) from public.audit_logs where action = 'session.revoked_others' and user_id = '${owner}'`));
    await p.goto(k.APP + "/settings/profile/security");
    await p.click('button:has-text("Sign out other devices")');
    await p.click('.zs-dialog button:has-text("Sign out others")');
    await p.waitForSelector("text=This device stays signed in.");
    const after = Number(k.sql(`select count(*) from public.audit_logs where action = 'session.revoked_others' and user_id = '${owner}'`));
    k.check(`${tag}: sign out other devices goes through the database and is audited`, after === before + 1 && count(owner) === 0, `audit ${before}->${after}, left ${count(owner)}`);
    await p.waitForTimeout(800); await p.screenshot({ path: path.join(SHOTS, `security-signed-out-${tag}.png`), fullPage: false });
    k.check(`${tag}: no page errors`, p.errors.length === 0, p.errors.join(" | "));
    await ctx.close();
  }
  await browser.close();
  k.sql(`update public.platform_admins set role = 'read_only_admin' where user_id = '${target}'`);
  console.log(k.failures() ? `${k.failures()} FAILED` : "ALL PASSED");
  process.exit(k.failures() ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
