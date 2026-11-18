// Unit tests for the PLT-08 scanner and drift check. Run: node --test tests/catalog/
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  sqlAuditActions, sqlAlertKinds, sqlPermissions, resolveSql, tsAuditActions, tsAuditReads, tsPermissions,
  n8nAlertKinds, webPermissions, sqlExprNames,
} from "./scan.mjs";
import { check } from "./drift_test.mjs";
import { jsValueBranches } from "./scan.mjs";

const names = (list) => list.map((f) => (f.prefix ? f.name + "*" : f.unresolved ? "?" + f.name : f.name)).sort();

test("SQL audit inserts: literal, case, literal joined to case, prefix, several tuples", () => {
  const src = `
    insert into public.audit_logs (business_id, user_id, action, entity_type) values (b, u, 'customer.added', 'customer');
    insert into audit_logs (action, entity_type) values (case when x then 'a.one' else 'a.two' end, 'e'), ('a.three', 'e');
    INSERT INTO public.audit_logs (user_id, action) VALUES (u, 'automation.' || case p when 'active' then 'resumed' else 'paused' end);
    insert into public.audit_logs (user_id, action) values (u, 'attendance.' || p_action);
    insert into public.audit_logs (business_id, action) select b.id, 'business.request_seen' from b;`;
  assert.deepEqual(names(sqlAuditActions(src)), ["a.one", "a.three", "a.two", "attendance.*", "automation.paused", "automation.resumed", "business.request_seen", "customer.added"]);
});

test("SQL audit inserts inside a patched function body (doubled quotes)", () => {
  const src = `select zella_patch_function('f', 'anchor', 'insert into public.audit_logs (user_id, action) values (auth.uid(), ''billing.pack_granted'');');`;
  assert.deepEqual(names(sqlAuditActions(src)), ["billing.pack_granted"]);
});

test("SQL: a variable is followed to its assignments and a parameter to every call", () => {
  const src = `
    create or replace function public.trg() returns trigger as $$
    declare v_action text;
    begin
      if tg_op = 'INSERT' then v_action := 'thing_added'; else v_action := 'thing_removed'; end if;
      insert into public.audit_logs (user_id, action) values (auth.uid(), v_action);
    end $$;
    create or replace function public.helper(p_business uuid, p_action text) returns void as $$
      insert into public.audit_logs (business_id, action) values (p_business, p_action);
    $$;
    create or replace function public.caller() returns void as $$
    begin
      perform public.helper(b, 'helper.used');
      perform public.helper(b, case when y then 'helper.new' else 'helper.old' end);
    end $$;
    grant execute on function public.helper(uuid, text) to service_role;`;
  const files = [{ rel: "x.sql", src }];
  assert.deepEqual(names(resolveSql(sqlAuditActions(src), src, files)), ["helper.new", "helper.old", "helper.used", "thing_added", "thing_removed"]);
});

test("SQL: an audit name that can't be followed is reported, never skipped", () => {
  const src = `insert into public.audit_logs (user_id, action) values (u, (select a from t));`;
  const out = sqlAuditActions(src);
  assert.equal(out.length, 1);
  assert.equal(out[0].unresolved, true);
});

test("SQL alert kinds and permissions", () => {
  const src = `
    create or replace function public.zella_platform_alert(p_kind text, p_title text) returns uuid as $$ select 1 $$;
    perform public.zella_platform_alert('queue_backlog', 'Queue', null);
    perform zella_platform_alert('reconcile_' || v_k || '_stuck', 'x');
    if not public.zella_admin_can('billing.view') then raise exception 'NOT_ALLOWED'; end if;
    insert into public.platform_role_permissions (role, permission) values ('support_admin', 'support.manage'), ('read_only_admin', 'audit.view');`;
  assert.deepEqual(names(sqlAlertKinds(src)), ["queue_backlog", "reconcile_*"]);
  assert.deepEqual(names(sqlPermissions(src)), ["audit.view", "billing.view", "support.manage"]);
});

test("TypeScript audit entries: literals, ternaries, templates and joins; request actions and comments ignored", () => {
  const src = `
    // action: "commented.out"
    const AUDITED = {
      a: () => ({ action: r.created ? "plan.created" : "plan.updated", entity_type: "plan" }),
      b: (r) => ({ action: \`legal.\${r.to}\`, entity_type: "x" }),
      c: (r) => ({ action: "platform.alert_" + r.status }),
    };
    await fetch(u, { body: JSON.stringify({ action: "lookup" }) });`;
  assert.deepEqual(names(tsAuditActions(src)), ["legal.*", "plan.created", "plan.updated", "platform.alert_*"]);
});

test("TypeScript audit reads and permission maps", () => {
  const src = `
    admin.from("audit_logs").select("a").in("action", ["platform.setting_updated", "platform.roles_updated"]);
    admin.from("audit_logs").select("a").or("action.like.session.%,action.like.admin%");
    export const NEW_PERMISSIONS: Record<string, string> = { thing_list: "businesses.view", thing_save: "security.manage" };
    const owner = ["admins.manage", "roles.manage"];`;
  assert.deepEqual(names(tsAuditReads(src)), ["admin*", "platform.roles_updated", "platform.setting_updated", "session.*"]);
  assert.deepEqual(names(tsPermissions(src)), ["admins.manage", "businesses.view", "roles.manage", "security.manage"]);
});

test("n8n alert kinds and web permission checks", () => {
  assert.deepEqual(names(n8nAlertKinds(`return { json: { alert: { p_kind: 'workflow_failed', p_title: 'x' } } };
    return run('zella_resolve_platform_alerts', { p_kind: 'integration_disconnected' });`)), ["workflow_failed"]);
  assert.deepEqual(names(webPermissions(`{ to: "/x", permission: "billing.view" } ; if (can("audit.view")) {}`)), ["audit.view", "billing.view"]);
});

test("sqlExprNames keeps a cast literal", () => {
  assert.deepEqual(sqlExprNames("'session.revoked'::text"), [{ name: "session.revoked" }]);
});

const CATALOG = {
  audit_actions: { "a.one": "One", "legal.draft": "Draft", "legal.published": "Published" },
  audit_action_prefixes: ["legal."],
  alert_kinds: { queue_backlog: "Queue backlog" },
  alert_kind_prefixes: [],
  permissions: { "admins.manage": "Admins", "audit.view": "Audit" },
  owner_only_permissions: ["admins.manage"],
};
const USES = [
  { kind: "audit", name: "a.one", where: "f:1" }, { kind: "audit", name: "legal.", prefix: true, where: "f:2" },
  { kind: "alert", name: "queue_backlog", where: "f:3" },
  { kind: "permission", name: "audit.view", where: "f:4" }, { kind: "permission", name: "admins.manage", where: "f:5" },
];

test("check: the current names pass", () => {
  assert.deepEqual(check(USES, CATALOG, { permissionCatalog: ["audit.view"], webLabels: ["a.one"] }), []);
});

test("check: a new unlabelled audit action, alert kind or permission fails", () => {
  const p = check([...USES, { kind: "audit", name: "a.new", where: "new.ts:9" }, { kind: "alert", name: "new_kind", where: "x.sql:3" },
    { kind: "permission", name: "growth.manage", where: "y.ts:1" }], CATALOG);
  assert.ok(p.some((x) => x.startsWith('new.ts:9: audit action "a.new" is not in audit_actions')));
  assert.ok(p.some((x) => x.startsWith('x.sql:3: alert kind "new_kind"')));
  assert.ok(p.some((x) => x.startsWith('y.ts:1: permission "growth.manage"')));
});

test("check: an undeclared run time prefix, an unresolved name and a stale entry fail", () => {
  const p = check([...USES.filter((u) => u.name !== "a.one"), { kind: "audit", name: "offer.", prefix: true, where: "o.sql:1" },
    { kind: "audit", name: "v_x", unresolved: true, where: "u.sql:2" }], CATALOG);
  assert.ok(p.some((x) => x.includes('add "offer." to audit_action_prefixes')));
  assert.ok(p.some((x) => x.startsWith("u.sql:2: can't tell")));
  assert.ok(p.some((x) => x.includes('"a.one" is no longer written')));
});

test("check: reads that match nothing, label rules, order and the role editor list", () => {
  const bad = { ...CATALOG, audit_actions: { "legal.published": "Published", "legal.draft": "Set up re-run", "a.one": "" } };
  const p = check([...USES, { kind: "audit_read", name: "roles", prefix: true, where: "s.ts:5" }], bad,
    { permissionCatalog: ["audit.view", "admins.manage"], webLabels: ["gone.label"] });
  assert.ok(p.some((x) => x.startsWith('s.ts:5: reads audit action "roles%"')));
  assert.ok(p.some((x) => x.includes('"a.one" has no label')));
  assert.ok(p.some((x) => x.includes("dash or hyphen")));
  assert.ok(p.some((x) => x.includes("keep audit_actions sorted")));
  assert.ok(p.some((x) => x.includes('"admins.manage" is not a catalog.json permission')));
  assert.ok(p.some((x) => x.includes('"gone.label" is not an audit action')));
});

test("review fixes: comments, case branches that aren't literals, every alert tuple, double quoted n8n kinds", () => {
  assert.deepEqual(names(sqlAuditActions(`-- insert into public.audit_logs (action) values ('removed.action');
    /* insert into audit_logs (action) values ('block.action'); */
    insert into public.audit_logs (action, new_data) values ('kept.action', jsonb_build_object('note', '-- not a comment'));`)), ["kept.action"]);
  assert.deepEqual(names(sqlAuditActions(`insert into audit_logs (action) values (case when f then 'a.one' else lower(x) end);`)), ["?lower(x)", "a.one"]);
  const src = `create or replace function public.h(p_action text) returns void as $$
    insert into audit_logs (action) values (case when f then 'a.one' else p_action end); $$;
    select public.h('a.two');`;
  assert.deepEqual(names(resolveSql(sqlAuditActions(src), src, [{ rel: "x.sql", src }])), ["a.one", "a.two"]);
  assert.deepEqual(names(sqlAlertKinds(`insert into public.platform_alerts (kind, title) values ('queue_backlog', 't'), ('new_kind', 't');`)), ["new_kind", "queue_backlog"]);
  assert.deepEqual(names(n8nAlertKinds(`return run("zella_platform_alert", { p_kind: "new_kind" });`)), ["new_kind"]);
});

test("review fixes: a variable set from a parameter is followed to the callers too", () => {
  const src = `create or replace function public.h(p_action text) returns void as $$
    declare v_action text; begin
      if x then v_action := 'a.one'; else v_action := p_action; end if;
      insert into audit_logs (action) values (v_action); end $$;
    select public.h('a.two');`;
  assert.deepEqual(names(resolveSql(sqlAuditActions(src), src, [{ rel: "x.sql", src }])), ["a.one", "a.two"]);
  const loop = `create or replace function public.g() returns void as $$
    declare v_a text; v_b text; begin v_a := v_b; v_b := v_a; insert into audit_logs (action) values (v_a); end $$;`;
  assert.ok(resolveSql(sqlAuditActions(loop), loop, [{ rel: "y.sql", src: loop }]).some((n) => n.unresolved), "a cycle ends unresolved");
});

test("review fixes: a TypeScript audit action held in a variable is reported, types and literals are not", () => {
  assert.deepEqual(jsValueBranches(`r.created ? "a.b" : next`), ["S", "next"]);
  assert.deepEqual(jsValueBranches(`"a.b" + r.to`), ["S + r.to"]);
  assert.deepEqual(names(tsAuditActions(`const nextAction = "plan.new"; const e = { action: nextAction, entity_type: "plan" };`)), ["?nextAction"]);
  assert.deepEqual(names(tsAuditActions(`const e = { action: r.ok ? "plan.created" : other };`)), ["?r.ok ? \"plan.created\" : other", "plan.created"]);
  assert.deepEqual(names(tsAuditActions(`type T = { action: string; }; const n = { action: null };`)), []);
});

test("review fixes 2: parenthesised branches are values, named types are not", () => {
  assert.deepEqual(jsValueBranches(`(r.ok ? "a.b" : "c.d")`), ["S", "S"]);
  assert.deepEqual(jsValueBranches(`r.ok ? ("a.b") : (other)`), ["S", "other"]);
  assert.deepEqual(names(tsAuditActions(`const e = { action: (r.ok ? "plan.created" : "plan.updated") };`)), ["plan.created", "plan.updated"]);
  assert.deepEqual(names(tsAuditActions(`type RequestAction = "lookup" | "start"; function handle(action: RequestAction) {} type T = { action: Action[] };`)), []);
  assert.deepEqual(names(tsAuditActions(`const e = { action: (next) };`)), ["?(next)"]);
});

test("review fixes 3: a PascalCase value in an object literal is a value, not a type", () => {
  assert.deepEqual(names(tsAuditActions(`const NextAction = "plan.new"; const e = { action: NextAction, entity_type: "plan" };`)), ["?NextAction"]);
  assert.deepEqual(names(tsAuditActions(`await audit({ action: NextAction }); const z = { entry: { action: Other } };`)), ["?NextAction", "?Other"]);
  assert.deepEqual(names(tsAuditActions(`interface I { action: Foo; } const f = (p: { action: Foo }) => p; const x: { action: Foo } = y;`)), []);
  assert.deepEqual(names(tsAuditActions(`const g = async (n: number, action: Foo): Promise<void> => {}; function h(): { action: Foo } { return y; }`)), []);
});

test("review fixes 4: whole case arms, the outer select list, quoted keys, audit queries only, alert objects of any length", () => {
  // a case arm joined to a column: its known start, not just the first token
  assert.deepEqual(names(sqlExprNames(`case when x then 'attendance.' || new_status else 'attendance.none' end`)), ["attendance.*", "attendance.none"]);
  // a from inside brackets doesn't end the select list, so the action after it is still read
  assert.deepEqual(names(sqlAuditActions(`insert into audit_logs (entity_id, action) select (select id from t limit 1), 'a.after' from x;`)), ["a.after"]);
  assert.deepEqual(names(tsAuditActions(`const e = { "action": "plan.quoted" }; const f = { 'action': "plan.single" };`)), ["plan.quoted", "plan.single"]);
  // an action filter on another table is not an audit read
  assert.deepEqual(names(tsAuditReads(`admin.from("audit_logs").select("id").eq("action", "a.read"); admin.from("jobs").select("id").eq("action", "not.audit");`)), ["a.read"]);
  const title = "x".repeat(300);
  assert.deepEqual(names(n8nAlertKinds(`await run("zella_platform_alert", { p_title: "${title}", p_detail: "${title}", p_kind: "long_kind" });
    await run("zella_resolve_platform_alerts", { p_kind: "resolved_kind" }); const other = { p_kind: "not_an_alert" };`)), ["long_kind"]);
});

test("review fixes 4: drift check uses own catalog entries, refuses run time permissions, reads single quoted label keys", async () => {
  const { labelKeys } = await import("./drift_test.mjs");
  const cat = { audit_actions: { "a.one": "One" }, alert_kinds: {}, permissions: {}, owner_only_permissions: [] };
  const p = check([{ kind: "audit", name: "a.one", where: "x:1" }, { kind: "audit", name: "constructor", where: "y:2" },
    { kind: "permission", name: "billing.", prefix: true, where: "z:3" }], cat, { webLabels: ["toString", "a.one"] });
  assert.ok(p.some((x) => x.includes('"constructor" is not in audit_actions')), p.join("\n"));
  assert.ok(p.some((x) => x.includes("builds a permission")), p.join("\n"));
  assert.ok(p.some((x) => x.includes('"toString" is not an audit action')), p.join("\n"));
  assert.deepEqual(labelKeys(`\n  "a.one": "One",\n  'a.stale': "Stale",\n  "a.mixed': "x",\n`), ["a.one", "a.stale"]);
});

test("review fixes 5: quoted names, query receivers, quoted alert keys, computed label keys", async () => {
  // a "from" or "end" used as a quoted column name doesn't end the select list or a case
  assert.deepEqual(names(sqlAuditActions(`insert into audit_logs (x, action) select "from", 'a.after' from t;`)), ["a.after"]);
  assert.deepEqual(names(sqlExprNames(`case when "end" = 1 then 'a.one' else 'a.two' end`)), ["a.one", "a.two"]);
  // the receiver decides: a chain, a name bound to a query, and one that can't be told
  assert.deepEqual(names(tsAuditReads(`let q = admin.from("audit_logs").select("id"); q = q.order("x"); q = q.eq("action", "a.bound");`)), ["a.bound"]);
  assert.deepEqual(names(tsAuditReads(`let q = admin.from("jobs").select("id"); q = q.eq("action", "not.audit");`)), []);
  assert.deepEqual(names(tsAuditReads(`function f(query) { return query.eq("action", "a.unknown"); }`)).map((n) => n.startsWith("?")), [true]);
  assert.deepEqual(names(n8nAlertKinds(`return { json: { "alert": { p_kind: "quoted_kind", p_title: "x" } } };`)), ["quoted_kind"]);
  const { labelKeys } = await import("./drift_test.mjs");
  assert.deepEqual(labelKeys(`\n  ["gone.label"]: "Gone",\n  [dynamic]: "x",\n  "a.one": "One",\n`), ["gone.label", "a.one"]);
});


test("review fixes 6: dollar quotes, filter calls only, branch assignments, alert keys past comments, label keys anywhere", async () => {
  // double quotes inside a dollar quoted string are text, not a quoted name
  assert.deepEqual(names(sqlExprNames(`case when note = $msg$"\\""$msg$ then 'a.new' else 'a.old' end`)), ["a.new", "a.old"]);
  // a LIKE pattern that isn't in a filter call is not a query; one in a filter call on an unknown receiver still is
  assert.deepEqual(tsAuditReads(`const example = "action.like.demo.%";`), []);
  assert.deepEqual(names(tsAuditReads(`function f(query) { return query.or("action.like.demo.%"); }`)).map((n) => n.startsWith("?")), [true]);
  assert.deepEqual(names(tsAuditReads(`admin.from("audit_logs").select("id").or("action.like.a.pre.%")`)), ["a.pre.*"]);
  // an assignment in a branch can reach the filter: audit_logs if any can, ignored only when all are other tables
  assert.deepEqual(names(tsAuditReads(`let q = admin.from("audit_logs"); if (useJobs) q = admin.from("jobs"); q.eq("action", "a.branch");`)), ["a.branch"]);
  assert.deepEqual(names(tsAuditReads(`let q = admin.from("jobs"); if (x) q = admin.from("tasks"); q.eq("action", "not.audit");`)), []);
  // a long comment between alert: and the object
  assert.deepEqual(names(n8nAlertKinds(`const x = { alert: /* ${"a long note ".repeat(12)} */ { p_kind: "new_kind" } };`)), ["new_kind"]);
  // several static keys on one line, and none from a block comment
  const { labelKeys } = await import("./drift_test.mjs");
  assert.deepEqual(labelKeys(`\n  ["a.one"]: "One", ["gone.label"]: "Gone",\n  /*\n  ["c.comment"]: "C",\n  */\n  "b.x": f("a, b", { "in.side": 1 }),\n`), ["a.one", "gone.label", "b.x"]);
});

test("review fixes 7: regex values, any dollar tag, nested filter arguments, conditional and overwritten queries, RPC calls only", async () => {
  const { labelKeys } = await import("./drift_test.mjs");
  assert.deepEqual(labelKeys(`\n  "a.one": /[(]/.source, "gone.label": "Gone",\n  "b.two": x / 2, "c.three": "C",\n`), ["a.one", "gone.label", "b.two", "c.three"]);
  // dollar quote tags in any language, of any length
  assert.deepEqual(names(sqlExprNames(`case when note = $réponse$"$réponse$ then 'a.new' else 'a.old' end`)), ["a.new", "a.old"]);
  const tag = "$" + "t".repeat(80) + "$";
  assert.deepEqual(names(sqlExprNames("case when note = " + tag + '"' + tag + " then 'a.new' else 'a.old' end")), ["a.new", "a.old"]);
  // a pattern inside an argument expression of .or(...)
  assert.deepEqual(names(tsAuditReads(`admin.from("audit_logs").or(["action.like.a.new.%"].join(","))`)), ["a.new.*"]);
  // both arms of a conditional assignment; an overwritten binding doesn't reach the call
  assert.deepEqual(names(tsAuditReads(`const q = useJobs ? admin.from("jobs") : admin.from("audit_logs"); q.eq("action", "a.cond");`)), ["a.cond"]);
  assert.deepEqual(names(tsAuditReads(`let q = admin.from("audit_logs"); q = admin.from("jobs"); q.eq("action", "not.audit");`)), []);
  assert.deepEqual(names(tsAuditReads(`let q = admin.from("audit_logs"); if (x) { q = admin.from("jobs"); } q.eq("action", "a.maybe");`)), ["a.maybe"]);
  // an RPC name in an array is not a call
  assert.deepEqual(names(n8nAlertKinds(`const x = ["zella_platform_alert", /* note */ { p_kind: "sample_kind" }];`)), []);
  assert.deepEqual(names(n8nAlertKinds(`await rpc("zella_platform_alert", /* note */ { p_kind: "real_kind" });`)), ["real_kind"]);
});

test("review fixes 8: division after an object, comments before a filter call, property writes, unknown arms, bracketed bodies, keywords", async () => {
  const { labelKeys } = await import("./drift_test.mjs");
  assert.deepEqual(labelKeys(`\n  "a.one": { valueOf() { return 6; } } / 2, "gone.label": "Gone",\n  "b.re": /[(]/.source, "c.three": "C",\n`), ["a.one", "gone.label", "b.re", "c.three"]);
  assert.deepEqual(names(tsAuditReads(`admin.from("audit_logs").or ${" ".repeat(40)} ("action.like.a.missing.%")`)), ["a.missing.*"]);
  assert.deepEqual(names(tsAuditReads(`let q = admin.from("audit_logs"); state.q = admin.from("jobs"); q.eq("action", "a.prop");`)), ["a.prop"]);
  assert.deepEqual(names(tsAuditReads(`const q = useJobs ? admin.from("jobs") : fallback; q.eq("action", "a.arm");`)).map((n) => n.startsWith("?")), [true]);
  assert.deepEqual(names(tsAuditReads(`let q = admin.from("audit_logs"); if (useJobs) (q = admin.from("jobs")); q.eq("action", "a.paren");`)), ["a.paren"]);
  assert.deepEqual(names(n8nAlertKinds(`function f() { return ("zella_platform_alert", { p_kind: "sample_kind" }); }`)), []);
  assert.deepEqual(names(n8nAlertKinds(`await rpc("zella_platform_alert", { p_kind: "real_kind" });`)), ["real_kind"]);
});

test("review fixes 9: a regex after a block, a wrapped conditional", async () => {
  const { labelKeys } = await import("./drift_test.mjs");
  assert.deepEqual(labelKeys(`\n  "a.one": (() => { if (false) {} /[(]/.test("x"); return "One"; })(), "gone.label": "Gone",\n  "b.two": { valueOf() { return 6; } } / 2, "c.three": "C",\n`), ["a.one", "gone.label", "b.two", "c.three"]);
  assert.deepEqual(names(tsAuditReads(`const q = (useJobs ? admin.from("jobs") : fallback); q.eq("action", "a.wrapped");`)).map((n) => n.startsWith("?")), [true]);
  assert.deepEqual(names(tsAuditReads(`const q = (useJobs ? admin.from("jobs") : admin.from("tasks")); q.eq("action", "not.audit");`)), []);
});

test("review fixes 10: division after a function value, nested conditional arms", async () => {
  const { labelKeys } = await import("./drift_test.mjs");
  assert.deepEqual(labelKeys(`\n  "a.one": function () {} / 2, "gone.label": "Gone",\n  "b.two": (() => { if (false) {} /[(]/.test("x"); return "B"; })(), "c.three": "C",\n`), ["a.one", "gone.label", "b.two", "c.three"]);
  assert.deepEqual(names(tsAuditReads(`const q = useJobs ? admin.from("jobs") : (useTasks ? admin.from("tasks") : audit); q.eq("action", "a.nested");`)).map((n) => n.startsWith("?")), [true]);
  assert.deepEqual(names(tsAuditReads(`const q = useJobs ? admin.from("jobs") : (useTasks ? admin.from("tasks") : admin.from("audit_logs")); q.eq("action", "a.deep");`)), ["a.deep"]);
  assert.deepEqual(names(tsAuditReads(`const q = useJobs ? admin.from("jobs") : admin.from("tasks"); q.eq("action", "not.audit");`)), []);
  assert.deepEqual(names(tsAuditReads(`const q = useJobs ? admin.from("jobs") : audit; q.eq("action", "a.unknown");`)).map((n) => n.startsWith("?")), [true]);
});
