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
  try {
    for (const [width, tag] of [[1440, "desktop"], [390, "phone"]]) {
      k.sql(`update public.platform_admins set role = 'read_only_admin', is_active = true where user_id = '${target}'`);
      k.sql(`delete from auth.sessions where user_id in ('${owner}', '${target}')`);
      sessions(target, 2);
      // a session of theirs signed in through the stand in: its refresh works now, and must stop once they are signed out
      const theirs = await k.signInApi(TARGET);
      const before = await k.refresh(theirs.refresh_token);
      k.check(`${tag}: their refresh token works before the change`, before.status === 200 && typeof before.body.refresh_token === "string", String(before.status));
      const ctx = await k.context(browser, width);
      try {
        const p = await k.page(ctx);
        await k.signIn(p, OWNER);
        await p.goto(k.APP + "/users");
        const select = p.locator(`select[aria-label="Role for ${TARGET}"]`);
        await select.waitFor();
        await select.selectOption("support_admin");
        await p.waitForSelector("text=They will be signed out on every device.");
        k.check(`${tag}: changing a role warns they will be signed out on every device`, true);
        await p.waitForTimeout(800); await p.screenshot({ path: path.join(SHOTS, `users-confirm-${tag}.png`), fullPage: false });
        // this run's audit entry is the first one after this moment
        const since = k.sql("select clock_timestamp()::text");
        await p.click('button:has-text("Change role")');
        // ACC-19: a role change needs a new code when the last one is older than 5 minutes (the stand in's sign in has none)
        k.check(`${tag}: the change asks for a new authenticator code`, await k.freshCode(p));
        await p.waitForSelector("text=They were signed out on 3 devices.");
        k.check(`${tag}: after the change the page says all 3 devices were signed out`, true);
        k.check(`${tag}: and the database has none of their sessions left`, count(target) === 0, `${count(target)} left`);
        k.check(`${tag}: the role change is saved`, k.sql(`select role from public.platform_admins where user_id = '${target}'`) === "support_admin");
        const audit = k.sql(`select count(*) || '|' || count(*) filter (where new_data ->> 'sessions_ended' = '3') from public.audit_logs where action = 'admin.updated' and entity_id = '${target}' and created_at > '${since}'`);
        k.check(`${tag}: exactly one admin.updated entry for this change, recording 3 sessions ended`, audit === "1|1", audit);
        const refused = await k.refresh(before.body.refresh_token);
        k.check(`${tag}: a refresh token issued before the change no longer works`, refused.status === 400 && refused.body?.code === "session_not_found", `${refused.status} ${refused.body?.code ?? ""}`);
        await p.waitForTimeout(800); await p.screenshot({ path: path.join(SHOTS, `users-done-${tag}.png`), fullPage: false });

        // sign out other devices, from the owner's own security settings
        sessions(owner, 2);
        const mine = await k.pageSessionId(p);
        const audBefore = Number(k.sql(`select count(*) from public.audit_logs where action = 'session.revoked_others' and user_id = '${owner}'`));
        await p.goto(k.APP + "/settings/profile/security");
        await p.click('button:has-text("Sign out other devices")');
        await p.click('.zs-dialog button:has-text("Sign out others")');
        await p.waitForSelector("text=This device stays signed in.");
        const after = Number(k.sql(`select count(*) from public.audit_logs where action = 'session.revoked_others' and user_id = '${owner}'`));
        const left = k.sql(`select coalesce(string_agg(id::text, ','), '') from auth.sessions where user_id = '${owner}'`);
        k.check(`${tag}: sign out other devices goes through the database and is audited`, after === audBefore + 1, `audit ${audBefore}->${after}`);
        k.check(`${tag}: this device's session is the only one left`, Boolean(mine) && left === mine, `this ${mine}, left ${left}`);
        await p.waitForTimeout(800); await p.screenshot({ path: path.join(SHOTS, `security-signed-out-${tag}.png`), fullPage: false });
        k.check(`${tag}: no page errors`, p.errors.length === 0, p.errors.join(" | "));
      } finally {
        await ctx.close().catch(() => {});
        // the fixture's role, whether or not the steps above passed
        k.sql(`update public.platform_admins set role = 'read_only_admin', is_active = true where user_id = '${target}'`);
      }
    }
  } finally {
    await browser.close().catch(() => {});
    k.sql(`update public.platform_admins set role = 'read_only_admin', is_active = true where user_id = '${target}'`);
  }
  console.log(k.failures() ? `${k.failures()} FAILED` : "ALL PASSED");
  process.exit(k.failures() ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
