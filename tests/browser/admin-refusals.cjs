// ACC-15: refused calls to the admin function are recorded as security.admin_refused (ip and user agent), at most 5
// per person and reason in 10 minutes, and listed on Users & access; in a real browser against the local stand in
// over an ISOLATED test database. Desktop (1440x900) and phone (390 wide). Nothing is sent.
// Needs: the stand in process (local-backend.mjs) started with ZTEST_PASSWORD_AAL2=1, so admins with an authenticator
// reach the permission check; nofactor@lanea.test is created without an authenticator on purpose (MFA_SETUP_REQUIRED).
// Usage: ZDB=<test db> APP_URL=... BACKEND_URL=... SHOTS=<folder> node tests/browser/admin-refusals.cjs
const path = require("path");
const k = require("./real-kit.cjs");
const SHOTS = process.env.SHOTS ?? path.join(__dirname, "out", "admin-refusals");
const OWNER = "admin@zella.test", READONLY = "readonly@zella.test", MEMBER = "own-a@b3.test", NOFACTOR = "nofactor@lanea.test";
const H = { "x-forwarded-for": "203.0.113.7", "user-agent": "Refusal test browser" };
const rows = (email, code) => Number(k.sql(`select count(*) from public.audit_logs a join auth.users u on u.id = a.user_id where u.email = '${email}' and a.action = 'security.admin_refused' and a.new_data ->> 'code' = '${code}'`));

(async () => {
  k.guard();
  require("fs").mkdirSync(SHOTS, { recursive: true });
  k.sql(`delete from public.audit_logs where action = 'security.admin_refused'`);
  k.sql(`delete from public.rate_limits where key like 'refusal:%'`);
  k.sql(`insert into auth.users (id, email, email_confirmed_at) values (gen_random_uuid(), '${NOFACTOR}', now()) on conflict do nothing`);
  k.sql(`insert into public.platform_admins (user_id, role, is_active) select id, 'support_admin', true from auth.users where email = '${NOFACTOR}' on conflict (user_id) do update set is_active = true`);

  const total = () => Number(k.sql(`select count(*) from public.audit_logs where action = 'security.admin_refused'`));
  let r = await k.fn(null, { action: "dashboard_data" }, H);
  k.check("a call without sign in is refused and not recorded (no one to attribute it to)", r.status === 401 && total() === 0, `${r.status} ${total()}`);
  r = await k.fn(await k.token(MEMBER), { action: "dashboard_data" }, H);
  k.check("a business member calling the admin function is recorded (NOT_ADMIN)", r.status === 403 && rows(MEMBER, "NOT_ADMIN") === 1, `${r.status} ${rows(MEMBER, "NOT_ADMIN")}`);
  const detail = k.sql(`select host(ip_address) || '|' || user_agent from public.audit_logs where action = 'security.admin_refused' order by created_at desc limit 1`);
  k.check("with the ip address and user agent", detail === "203.0.113.7|Refusal test browser", detail);
  r = await k.fn(await k.token(NOFACTOR), { action: "dashboard_data" }, H);
  k.check("an admin without two step sign in is recorded (MFA_SETUP_REQUIRED)", r.status === 403 && r.body.code === "MFA_SETUP_REQUIRED" && rows(NOFACTOR, "MFA_SETUP_REQUIRED") === 1, `${r.status} ${r.body.code}`);
  const ro = await k.token(READONLY);
  r = await k.fn(ro, { action: "admin_invite", email: "x@lanea.test" }, H);
  const perm = k.sql(`select new_data ->> 'action' || '|' || (new_data ->> 'permission') from public.audit_logs where action = 'security.admin_refused' and new_data ->> 'code' = 'NOT_PERMITTED' limit 1`);
  k.check("a role without the permission is recorded (NOT_PERMITTED) with the action and permission", r.status === 403 && perm === "admin_invite|admins.manage", `${r.status} ${perm}`);
  const answers = [];
  for (let i = 0; i < 8; i++) answers.push(await k.fn(ro, { action: "admin_invite", email: "x@lanea.test" }, H));
  const allRefused = answers.every((a) => a.status === 403 && a.body.code === "NOT_PERMITTED");
  k.check("a flood is capped at 5 rows per person and reason in 10 minutes, and every answer is still the refusal", rows(READONLY, "NOT_PERMITTED") === 5 && allRefused, `${rows(READONLY, "NOT_PERMITTED")} rows, ${answers.map((a) => `${a.status}:${a.body.code}`).join(" ")}`);
  const fine = await k.fn(await k.token(OWNER), { action: "admins_list" }, H);
  k.check("an allowed call records nothing", fine.status === 200 && total() === 7, `${fine.status} ${total()}`);

  const browser = await k.chromium.launch();
  for (const [width, tag] of [[1440, "desktop"], [390, "phone"]]) {
    const ctx = await k.context(browser, width);
    const p = await k.page(ctx);
    await k.signIn(p, OWNER);
    await p.goto(k.APP + "/users");
    await p.waitForSelector("text=Refused admin requests");
    await p.waitForSelector("text=Their role doesn't allow it: add, change and remove platform admins (Zella Voice owner only)");
    k.check(`${tag}: Users & access lists the refused requests in words`, await p.isVisible("text=Two step sign in not set up") && await p.isVisible("text=Not a Zella Voice admin"));
    k.check(`${tag}: with the count for 24 hours`, await p.isVisible("text=7 in the last 24 hours"));
    await p.locator("#refusals-title").scrollIntoViewIfNeeded();
    await p.waitForTimeout(600); await p.screenshot({ path: path.join(SHOTS, `refusals-${tag}.png`), fullPage: true });
    k.check(`${tag}: no page errors`, p.errors.length === 0, p.errors.join(" | "));
    await ctx.close();
  }
  await browser.close();
  k.sql(`update public.platform_admins set is_active = false where user_id = (select id from auth.users where email = '${NOFACTOR}')`);
  console.log(k.failures() ? `${k.failures()} FAILED` : "ALL PASSED");
  process.exit(k.failures() ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
