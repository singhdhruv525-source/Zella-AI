// A local stand-in for Supabase, for browser tests ONLY. It answers the calls the web app and the edge functions make
// (REST tables, RPC functions, auth, edge functions, storage) against an ISOLATED Postgres restored from
// sql/baseline (no production data). Every database call runs as the signed-in role with the caller's token claims, so
// row security, grants and the functions' own permission checks are the real ones. Auth is simplified: test users only,
// one shared test password, tokens signed with a local test secret. No email, text or call is ever sent.
//
// Usage: node tests/browser/local-backend.mjs     (env: ZDB=zella_ui ZPG_HOST ZPG_PORT PORT=54321)
// Not a full PostgREST: it covers the query shapes this app uses (select with embeds, eq/neq/gt/gte/lt/lte/like/ilike/
// is/in/cs/not, or=, order, limit/offset, count, single object, insert/upsert/update/delete, rpc).
import { PSQL_ENV, requireIsolated } from "./isolated-db.cjs";
import http from "node:http";
import crypto from "node:crypto";
import { spawn } from "node:child_process";

const PORT = Number(process.env.PORT ?? 54321);
const DB = process.env.ZDB ?? "zella_ui";
const PGH = process.env.ZPG_HOST ?? "/var/lib/postgresql/zella-sec";
const PGP = process.env.ZPG_PORT ?? "55433";
export const SECRET = "zella-local-test-secret-not-for-production";
export const SERVER_KEY = "sb_secret_local_test_only";
export const ANON_KEY = "sb_publishable_local_test_only";
export const TEST_PASSWORD = "Test-pass-1";
const FUNCTIONS = JSON.parse(process.env.ZFUNCTIONS ?? "{}"); // { name: port }

// ---------- tokens ----------
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
export function sign(claims) {
  const head = b64({ alg: "HS256", typ: "JWT" }), body = b64(claims);
  return `${head}.${body}.${crypto.createHmac("sha256", SECRET).update(`${head}.${body}`).digest("base64url")}`;
}
function verify(token) {
  const [h, b, s] = String(token ?? "").split(".");
  if (!s) return null;
  const good = crypto.createHmac("sha256", SECRET).update(`${h}.${b}`).digest("base64url");
  if (good.length !== s.length || !crypto.timingSafeEqual(Buffer.from(good), Buffer.from(s))) return null;
  const c = JSON.parse(Buffer.from(b, "base64url").toString());
  return c.exp && c.exp < Date.now() / 1000 ? null : c;
}

// ---------- database ----------
const lit = (v) => { if (v === null || v === undefined) return "null"; const t = `$z${crypto.randomBytes(4).toString("hex")}$`; return `${t}${String(v)}${t}`; };
const ident = (s) => `"${String(s).replace(/"/g, '""')}"`;

function psql(sql) {
  return new Promise((resolve) => {
    const p = spawn("psql", ["-h", PGH, "-p", PGP, "-U", "postgres", "-d", DB, "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1", "-v", "VERBOSITY=verbose"], { env: PSQL_ENV });
    let out = "", err = "";
    p.stdout.on("data", (d) => (out += d)); p.stderr.on("data", (d) => (err += d));
    p.on("close", (code) => resolve({ code, out, err }));
    p.stdin.end(`\\set VERBOSITY verbose\n${sql}`);
  });
}

// Runs one statement that returns a single text value, as the caller.
async function asCaller(claims, statement, { preRequest = true, system = false } = {}) {
  const role = claims?.role === "service_role" ? "service_role" : claims?.sub ? "authenticated" : "anon";
  const sql = `begin;
${system ? "" : `set local role ${role};`}
select set_config('request.jwt.claims', ${lit(JSON.stringify(claims ?? { role: "anon" }))}, true) \\g /dev/null
${preRequest ? "select public.zella_pre_request() \\g /dev/null" : ""}
${statement};
commit;`;
  const r = await psql(sql);
  if (r.code !== 0) {
    const m = /ERROR:\s+([0-9A-Z]{5}):\s+([^\n]*)/.exec(r.err) ?? /ERROR:\s+([^\n]*)/.exec(r.err);
    const code = m && m[2] !== undefined ? m[1] : "XX000", message = m ? (m[2] ?? m[1]) : r.err.trim();
    const hint = /HINT:\s+([^\n]*)/.exec(r.err)?.[1] ?? null, details = /DETAIL:\s+([^\n]*)/.exec(r.err)?.[1] ?? null;
    return { error: { code, message, hint, details } };
  }
  return { text: r.out.replace(/\n$/, "") };
}
const pgStatus = (code, anon) =>
  code === "42501" ? (anon ? 401 : 403) : code === "23505" || code === "23503" ? 409 : code === "PGRST116" ? 406 : code?.startsWith("PGRST") ? 400 : code === "42883" || code === "42P01" ? 404 : 400;

// ---------- catalog (cached) ----------
let catalog = null;
async function loadCatalog() {
  if (catalog) return catalog;
  const r = await psql(`select json_build_object(
    'fks', (select json_agg(json_build_object('t', c.conrelid::regclass::text, 'r', c.confrelid::regclass::text, 'name', c.conname,
              'cols', (select json_agg(a.attname order by k.n) from unnest(c.conkey) with ordinality k(attnum, n) join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.attnum),
              'rcols', (select json_agg(a.attname order by k.n) from unnest(c.confkey) with ordinality k(attnum, n) join pg_attribute a on a.attrelid = c.confrelid and a.attnum = k.attnum)))
            from pg_constraint c where c.contype = 'f' and c.connamespace = 'public'::regnamespace),
    'fns', (select json_agg(json_build_object('name', p.proname, 'args', coalesce(p.proargnames, '{}'), 'types', (select json_agg(format_type(t, null) order by n) from unnest(p.proargtypes) with ordinality u(t, n)),
              'modes', p.proargmodes, 'nargs', p.pronargs, 'ndef', p.pronargdefaults, 'set', p.proretset, 'ret', format_type(p.prorettype, null), 'rettyp', (select typtype from pg_type where oid = p.prorettype)))
            from pg_proc p where p.pronamespace = 'public'::regnamespace))`);
  catalog = JSON.parse(r.out);
  return catalog;
}
const bare = (rel) => rel.replace(/^public\./, "").replace(/"/g, "");

// ---------- select parsing ----------
function splitTop(s, sep = ",") {
  const out = []; let depth = 0, cur = "";
  for (const ch of s) {
    if (ch === "(") depth++; if (ch === ")") depth--;
    if (ch === sep && depth === 0) { out.push(cur); cur = ""; } else cur += ch;
  }
  if (cur.trim()) out.push(cur);
  return out.map((x) => x.trim()).filter(Boolean);
}
async function selectList(table, alias, select, depth = 0) {
  const parts = splitTop(select || "*");
  const cols = [];
  for (const part of parts) {
    const m = /^(?:([a-zA-Z0-9_]+):)?([a-zA-Z0-9_]+)(?:!([a-zA-Z0-9_]+))?\((.*)\)$/s.exec(part);
    if (m) { cols.push(await embed(table, alias, m[1] ?? m[2], m[2], m[3], m[4], depth)); continue; }
    if (part === "*") { cols.push(`${alias}.*`); continue; }
    const c = /^(?:([a-zA-Z0-9_]+):)?([a-zA-Z0-9_]+)(?:::([a-z0-9_]+))?$/.exec(part);
    if (!c) throw new Error(`unsupported select: ${part}`);
    cols.push(`${alias}.${ident(c[2])}${c[3] ? `::${c[3]}` : ""} as ${ident(c[1] ?? c[2])}`);
  }
  return cols.join(", ");
}
async function embed(table, alias, as, target, hint, inner, depth) {
  const { fks } = await loadCatalog();
  const a2 = `e${depth}_${target}`;
  const sub = await selectList(target, a2, inner, depth + 1);
  const hintOk = (f) => !hint || hint === "inner" || f.name === hint || f.cols.includes(hint);
  const one = fks.find((f) => bare(f.t) === table && bare(f.r) === target && hintOk(f));
  if (one) {
    const on = one.cols.map((c, i) => `${a2}.${ident(one.rcols[i])} = ${alias}.${ident(c)}`).join(" and ");
    return `(select row_to_json(x) from (select ${sub} from public.${ident(target)} ${a2} where ${on} limit 1) x) as ${ident(as)}`;
  }
  const many = fks.find((f) => bare(f.t) === target && bare(f.r) === table && hintOk(f));
  if (many) {
    const on = many.cols.map((c, i) => `${a2}.${ident(c)} = ${alias}.${ident(many.rcols[i])}`).join(" and ");
    return `coalesce((select json_agg(x) from (select ${sub} from public.${ident(target)} ${a2} where ${on}) x), '[]'::json) as ${ident(as)}`;
  }
  throw Object.assign(new Error(`Could not find a relationship between '${table}' and '${target}'`), { pgrst: "PGRST200" });
}

// ---------- filters ----------
function parseValue(op, raw, col) {
  const unq = (v) => (v.startsWith('"') && v.endsWith('"') ? v.slice(1, -1) : v);
  switch (op) {
    case "eq": return `${col} = ${lit(unq(raw))}`;
    case "neq": return `${col} <> ${lit(unq(raw))}`;
    case "gt": return `${col} > ${lit(unq(raw))}`;
    case "gte": return `${col} >= ${lit(unq(raw))}`;
    case "lt": return `${col} < ${lit(unq(raw))}`;
    case "lte": return `${col} <= ${lit(unq(raw))}`;
    case "like": return `${col}::text like ${lit(unq(raw).replace(/\*/g, "%"))}`;
    case "ilike": return `${col}::text ilike ${lit(unq(raw).replace(/\*/g, "%"))}`;
    case "is": return `${col} is ${{ null: "null", true: "true", false: "false", unknown: "unknown" }[raw.toLowerCase()] ?? "null"}`;
    case "in": { const items = splitTop(raw.replace(/^\(/, "").replace(/\)$/, "")).map(unq); return items.length ? `${col} in (${items.map(lit).join(", ")})` : "false"; }
    case "cs": return raw.startsWith("{") ? `${col} @> ${lit(raw)}` : `${col} @> ${lit(raw)}::jsonb`;
    case "cd": return `${col} <@ ${lit(raw)}`;
    case "ov": return `${col} && ${lit(raw.replace(/^\(/, "{").replace(/\)$/, "}"))}`;
    default: throw new Error(`unsupported operator ${op}`);
  }
}
function condition(alias, key, value) {
  const not = value.startsWith("not.");
  const v = not ? value.slice(4) : value;
  const dot = v.indexOf(".");
  const op = v.slice(0, dot), raw = v.slice(dot + 1);
  const path = key.split("->");
  const col = path.length > 1 ? `${alias}.${ident(path[0])}->>${lit(path.slice(1).join("->").replace(/^>/, ""))}` : `${alias}.${ident(key)}`;
  const c = parseValue(op, raw, col);
  return not ? `not (${c})` : c;
}
function logic(alias, kind, body) {
  const items = splitTop(body.replace(/^\(/, "").replace(/\)$/, ""));
  return `(${items.map((it) => {
    const nested = /^(not\.)?(or|and)\((.*)\)$/s.exec(it);
    if (nested) return `${nested[1] ? "not " : ""}${logic(alias, nested[2], `(${nested[3]})`)}`;
    const i = it.indexOf(".");
    return condition(alias, it.slice(0, i), it.slice(i + 1));
  }).join(` ${kind} `)})`;
}
const RESERVED = new Set(["select", "order", "limit", "offset", "on_conflict", "columns"]);
function where(alias, params) {
  const c = [];
  for (const [k, v] of params) {
    if (RESERVED.has(k) || k.includes(".")) continue;   // embedded-resource filters are not supported (not used)
    if (k === "or" || k === "and") c.push(logic(alias, k, v));
    else if (k === "not.or" || k === "not.and") c.push(`not ${logic(alias, k.slice(4), v)}`);
    else c.push(condition(alias, k, v));
  }
  return c.length ? `where ${c.join(" and ")}` : "";
}
function orderBy(alias, order) {
  if (!order) return "";
  return `order by ${order.split(",").map((o) => {
    const [col, ...mods] = o.split(".");
    return `${alias}.${ident(col)} ${mods.includes("desc") ? "desc" : "asc"}${mods.includes("nullsfirst") ? " nulls first" : mods.includes("nullslast") ? " nulls last" : ""}`;
  }).join(", ")}`;
}

// ---------- handlers ----------
async function rest(req, url, claims, body) {
  const table = decodeURIComponent(url.pathname.replace(/^\/rest\/v1\//, ""));
  const params = [...url.searchParams.entries()];
  const q = Object.fromEntries(params);
  const prefer = String(req.headers.prefer ?? "");
  const object = String(req.headers.accept ?? "").includes("vnd.pgrst.object");
  const anon = !claims?.sub && claims?.role !== "service_role";
  if (table.startsWith("rpc/")) return rpc(table.slice(4), req.method === "GET" ? Object.fromEntries(params) : body ?? {}, claims, req.method === "HEAD", object);
  const t = `public.${ident(table)}`;
  let stmt;
  if (req.method === "GET" || req.method === "HEAD") {
    const cols = await selectList(table, "t", q.select);
    const base = `from ${t} t ${where("t", params)}`;
    const count = prefer.includes("count=") ? `(select count(*) ${base})` : "null";
    stmt = `select json_build_object('rows', coalesce((select json_agg(r) from (select ${cols} ${base} ${orderBy("t", q.order)} ${q.limit ? `limit ${Number(q.limit)}` : ""} ${q.offset ? `offset ${Number(q.offset)}` : ""}) r), '[]'::json), 'count', ${count})`;
  } else if (req.method === "POST") {
    const rows = Array.isArray(body) ? body : [body];
    const keys = q.columns ? q.columns.replace(/"/g, "").split(",") : [...new Set(rows.flatMap((r) => Object.keys(r ?? {})))];
    const list = keys.map(ident).join(", ");
    let conflict = "";
    if (prefer.includes("resolution=merge-duplicates") || prefer.includes("resolution=ignore-duplicates")) {
      const target = q.on_conflict ? `(${q.on_conflict.split(",").map(ident).join(", ")})` : "";
      conflict = prefer.includes("ignore-duplicates") ? `on conflict ${target} do nothing` : `on conflict ${target} do update set ${keys.map((k) => `${ident(k)} = excluded.${ident(k)}`).join(", ")}`;
    }
    const sel = q.select ? await selectList(table, "t", q.select) : "t.*";
    stmt = `with ins as (insert into ${t} (${list}) select ${list} from json_populate_recordset(null::${t}, ${lit(JSON.stringify(rows))}) ${conflict} returning *)
      select json_build_object('rows', coalesce((select json_agg(r) from (select ${sel} from ins t) r), '[]'::json), 'count', null)`;
  } else if (req.method === "PATCH") {
    const keys = Object.keys(body ?? {});
    const sel = q.select ? await selectList(table, "t", q.select) : "t.*";
    stmt = `with up as (update ${t} t set (${keys.map(ident).join(", ")}) =
        (select ${keys.map((k) => `p.${ident(k)}`).join(", ")} from json_populate_record(null::${t}, ${lit(JSON.stringify(body))}) p) ${where("t", params)} returning t.*)
      select json_build_object('rows', coalesce((select json_agg(r) from (select ${sel} from up t) r), '[]'::json), 'count', null)`;
  } else if (req.method === "DELETE") {
    stmt = `with del as (delete from ${t} t ${where("t", params)} returning t.*) select json_build_object('rows', coalesce((select json_agg(r) from del r), '[]'::json), 'count', null)`;
  } else return { status: 405, json: { message: "method" } };
  const r = await asCaller(claims, stmt);
  if (r.error) return { status: pgStatus(r.error.code, anon), json: r.error };
  const { rows, count } = JSON.parse(r.text);
  const headers = count !== null ? { "content-range": `${rows.length ? `0-${rows.length - 1}` : "*"}/${count}` } : {};
  if (object) {
    if (rows.length !== 1) return { status: 406, json: { code: "PGRST116", message: "JSON object requested, multiple (or no) rows returned", details: `The result contains ${rows.length} rows`, hint: null } };
    return { status: 200, json: rows[0], headers };
  }
  if (req.method !== "GET" && req.method !== "HEAD" && !prefer.includes("return=representation")) return { status: 204, headers };
  return { status: req.method === "POST" ? 201 : 200, json: rows, headers, head: req.method === "HEAD" };
}

async function rpc(name, args, claims, head, object) {
  const { fns } = await loadCatalog();
  const keys = Object.keys(args ?? {});
  const anon = !claims?.sub && claims?.role !== "service_role";
  const cands = fns.filter((f) => f.name === name).filter((f) => {
    const ins = f.args.slice(0, f.nargs);
    return keys.every((k) => ins.includes(k)) && ins.slice(0, f.nargs - f.ndef).every((a) => keys.includes(a));
  });
  if (!cands.length) return { status: 404, json: { code: "PGRST202", message: `Could not find the function public.${name}(${keys.join(", ")}) in the schema cache`, hint: null, details: null } };
  const f = cands.sort((a, b) => a.nargs - b.nargs)[0];
  const j = lit(JSON.stringify(args ?? {}));
  const call = `public.${ident(name)}(${keys.map((k) => {
    const type = f.types[f.args.indexOf(k)];
    const v = `(${j}::jsonb -> ${lit(k)})`;
    const expr = /json/.test(type) ? `${v}::${type}`
      : type.endsWith("[]") ? `(case when jsonb_typeof(${v}) = 'array' then array(select jsonb_array_elements_text(${v}))::${type} end)`
      : `(${j}::jsonb ->> ${lit(k)})::${type}`;
    return `${ident(k)} => ${expr}`;
  }).join(", ")})`;
  const stmt = f.set ? `select coalesce(json_agg(r), '[]'::json) from ${call} r`
    : f.rettyp === "c" ? `select (select row_to_json(r) from ${call} r where r is not null)` : f.ret === "void" ? `select ${call} \\g /dev/null\nselect 'null'` : `select to_json(${call})`;
  const r = await asCaller(claims, stmt);
  if (r.error) return { status: pgStatus(r.error.code, anon), json: r.error };
  let value = r.text === "" ? null : JSON.parse(r.text);
  if (object && Array.isArray(value)) value = value[0] ?? null;
  return { status: 200, json: value, head };
}

async function userRow(id) {
  const r = await asCaller({ role: "service_role" }, `select row_to_json(u) from (select id, email, email_confirmed_at, last_sign_in_at, created_at, raw_user_meta_data, raw_app_meta_data,
      (select coalesce(json_agg(json_build_object('id', f.id, 'status', f.status, 'factor_type', f.factor_type, 'friendly_name', f.friendly_name)), '[]') from auth.mfa_factors f where f.user_id = u.id) factors
    from auth.users u where id = ${lit(id)}) u`, { preRequest: false, system: true });
  if (r.error || !r.text) return null;
  const u = JSON.parse(r.text);
  return { id: u.id, aud: "authenticated", role: "authenticated", email: u.email, email_confirmed_at: u.email_confirmed_at, confirmed_at: u.email_confirmed_at,
    last_sign_in_at: u.last_sign_in_at, created_at: u.created_at, updated_at: u.created_at, app_metadata: { provider: "email", ...(u.raw_app_meta_data ?? {}) },
    user_metadata: u.raw_user_meta_data ?? {}, identities: [], factors: u.factors };
}
// amr as Supabase Auth sends it: the password time, plus the time an authenticator code was last entered for this
// session (totpAt), which a refresh keeps and only a verified code moves on (ACC-19). Like Supabase Auth, every
// session is a row in auth.sessions (session_id in the token), and a refresh token is opaque: what it stands for is
// kept here, never read from the token, so editing a token can't change its level or code time. A refresh needs the
// session row to still exist, so ending a session (zella_end_user_sessions, zella_revoke_my_other_sessions) stops
// its refresh; an access token already issued keeps working until it expires, as with Supabase.
const REFRESH = new Map();   // refresh token -> { id, aal, totpAt, sid }
// One change at a time per session (a refresh, a verified code), in the order they arrive, so a refresh that started
// before a code was verified can't write the older level back after it.
const TURNS = new Map();     // session id -> the last queued change
function inTurn(sid, work) {
  if (!sid) return work();
  const run = (TURNS.get(sid) ?? Promise.resolve()).then(work, work);
  const tail = run.catch(() => {});
  TURNS.set(sid, tail);
  tail.then(() => { if (TURNS.get(sid) === tail) TURNS.delete(sid); });
  return run;
}
// Returns null when a session given by id no longer exists for that person (it was ended): no token is issued then.
async function session(user, aal = "aal1", totpAt = null, sid = null) {
  const sessionId = sid ?? crypto.randomUUID();
  const sys = { preRequest: false, system: true };
  const w = sid
    // an existing session (refresh, a new code): only its own row, never recreated once it was ended
    ? await asCaller({ role: "service_role" }, `update auth.sessions set aal = ${lit(aal)}, refreshed_at = now(), updated_at = now() where id = ${lit(sessionId)} and user_id = ${lit(user.id)} returning id`, sys)
    : await asCaller({ role: "service_role" }, `insert into auth.sessions (id, user_id, aal, created_at, updated_at) values (${lit(sessionId)}, ${lit(user.id)}, ${lit(aal)}, now(), now()) returning id`, sys);
  if (w.error) throw Object.assign(new Error("session write failed"), { status: 500 });
  if (!w.text) return null;
  return issue(user, aal, totpAt, sessionId);
}
// the tokens for a session row already written
function issue(user, aal, totpAt, sessionId) {
  const now = Math.floor(Date.now() / 1000), exp = now + 3600;
  const amr = [...(totpAt ? [{ method: "totp", timestamp: totpAt }] : []), { method: "password", timestamp: now }];
  const claims = { sub: user.id, email: user.email, role: "authenticated", aud: "authenticated", aal, amr, exp, session_id: sessionId };
  const refresh = `rt_${crypto.randomUUID().replace(/-/g, "")}`;
  REFRESH.set(refresh, { id: user.id, aal, totpAt, sid: sessionId });
  return { access_token: sign(claims), refresh_token: refresh, token_type: "bearer", expires_in: 3600, expires_at: exp, user };
}
const SESSION_NOT_FOUND = { status: 400, json: { error: "invalid_grant", error_description: "Session not found", msg: "Session not found", code: "session_not_found" } };
const INVALID_GRANT = { status: 400, json: { error: "invalid_grant", error_description: "Invalid login credentials", msg: "Invalid login credentials", code: "invalid_credentials" } };

async function auth(req, url, claims, body) {
  const path = url.pathname.replace(/^\/auth\/v1/, "");
  if (path === "/token") {
    let id = null;
    if (url.searchParams.get("grant_type") === "password") {
      if (body?.password !== TEST_PASSWORD) return { status: 400, json: { error: "invalid_grant", error_description: "Invalid login credentials", msg: "Invalid login credentials", code: "invalid_credentials" } };
      const r = await asCaller({ role: "service_role" }, `select id from auth.users where lower(email) = lower(${lit(body.email)})`, { preRequest: false, system: true });
      id = r.text || null;
    }
    // a refresh keeps the session's level (r.<user id>.<aal>), as Supabase does. Test only: with ZTEST_PASSWORD_AAL2=1 a
    // password sign in by someone who has a verified authenticator counts as already verified, so page crawls don't
    // stop at the code screen (every admin needs two step sign in, ACC-01). admin-mfa-journey.cjs runs without it.
    let aal = "aal1", totpAt = null, sid = null;
    if (process.env.ZTEST_PASSWORD_AAL2 === "1" && id) {
      const f = await asCaller({ role: "service_role" }, `select count(*) from auth.mfa_factors where user_id = ${lit(id)} and status = 'verified'`, { preRequest: false, system: true });
      if (Number(f.text) > 0) aal = "aal2";
    }
    if (url.searchParams.get("grant_type") === "refresh_token") {
      // only a token this stand in issued, used once, for a session that still exists; in the session's turn, so a code
      // verified meanwhile (which ends the older tokens) comes first or after, never in between
      const token = String(body?.refresh_token ?? "");
      const first = REFRESH.get(token);
      if (!first) return INVALID_GRANT;
      return inTurn(first.sid, async () => {
        const held = REFRESH.get(token);
        if (!held) return INVALID_GRANT;   // used, or ended by a verified code, while waiting for the turn
        const live = await asCaller({ role: "service_role" }, `select count(*) from auth.sessions where id = ${lit(held.sid)} and user_id = ${lit(held.id)}`, { preRequest: false, system: true });
        if (live.error) return { status: 500, json: { code: 500, msg: "The session could not be read", error_code: "unexpected_failure" } };   // the token stays usable
        if (Number(live.text) !== 1) { REFRESH.delete(token); return SESSION_NOT_FOUND; }
        const user = await userRow(held.id);
        if (!user) return INVALID_GRANT;
        const s = await session(user, held.aal, held.totpAt, held.sid).catch(() => "error");
        // a failed write issued nothing, so the token stays usable for a retry
        if (s === "error") return { status: 500, json: { code: 500, msg: "The session could not be saved", error_code: "unexpected_failure" } };
        REFRESH.delete(token);
        if (!s) return SESSION_NOT_FOUND;
        await asCaller({ role: "service_role" }, `update auth.users set last_sign_in_at = now() where id = ${lit(held.id)}`, { preRequest: false, system: true });
        return { status: 200, json: s };
      });
    }
    const user = id && (await userRow(id));
    if (!user) return INVALID_GRANT;
    await asCaller({ role: "service_role" }, `update auth.users set last_sign_in_at = now() where id = ${lit(id)}`, { preRequest: false, system: true });
    const s = await session(user, aal, totpAt, sid).catch(() => "error");
    if (s === "error") return { status: 500, json: { code: 500, msg: "The session could not be saved", error_code: "unexpected_failure" } };
    return s ? { status: 200, json: s } : { status: 400, json: { error: "invalid_grant", error_description: "Session not found", msg: "Session not found", code: "session_not_found" } };
  }
  if (path === "/user") {
    if (!claims?.sub) return { status: 401, json: { code: 401, msg: "Invalid token", error_code: "bad_jwt" } };
    if (req.method === "PUT") {
      if (body?.data) await asCaller({ role: "service_role" }, `update auth.users set raw_user_meta_data = coalesce(raw_user_meta_data, '{}') || ${lit(JSON.stringify(body.data))}::jsonb where id = ${lit(claims.sub)}`, { preRequest: false, system: true });
    }
    const user = await userRow(claims.sub);
    return user ? { status: 200, json: user } : { status: 404, json: { msg: "User not found" } };
  }
  if (path === "/logout") return { status: 204 };
  if (["/otp", "/recover", "/resend", "/magiclink"].includes(path)) return { status: 200, json: {} };
  // Authenticator apps (TOTP), test only: the one code that works is 123456. Verifying gives an aal2 session.
  if (path === "/factors" || path.startsWith("/factors/")) {
    if (!claims?.sub) return { status: 401, json: { code: 401, msg: "Invalid token", error_code: "bad_jwt" } };
    const sys = { preRequest: false, system: true };
    const [, , factorId, verb] = path.split("/");
    if (path === "/factors" && req.method === "POST") {
      const r = await asCaller({ role: "service_role" }, `insert into auth.mfa_factors (id, user_id, friendly_name, factor_type, status) values (gen_random_uuid(), ${lit(claims.sub)}, ${lit(body?.friendly_name ?? null)}, 'totp', 'unverified') returning id`, sys);
      // raw SVG, as Supabase sends it (the client adds the data: prefix)
      const qr = '<svg xmlns="http://www.w3.org/2000/svg" width="180" height="180"><rect width="180" height="180" fill="#eee"/><text x="20" y="95">TEST QR</text></svg>';
      return { status: 200, json: { id: r.text, type: "totp", friendly_name: body?.friendly_name ?? null, totp: { qr_code: qr, secret: "TESTSECRET123456", uri: "otpauth://totp/zella?secret=TESTSECRET123456" } } };
    }
    if (factorId && !verb && req.method === "DELETE") {
      await asCaller({ role: "service_role" }, `delete from auth.mfa_factors where id = ${lit(factorId)} and user_id = ${lit(claims.sub)}`, sys);
      return { status: 200, json: { id: factorId } };
    }
    if (verb === "challenge") return { status: 200, json: { id: crypto.randomUUID(), type: "totp", expires_at: Math.floor(Date.now() / 1000) + 300 } };
    if (verb === "verify") {
      if (String(body?.code ?? "") !== "123456") return { status: 422, json: { code: 422, msg: "Invalid TOTP code entered", error_code: "mfa_verification_failed" } };
      const user = await userRow(claims.sub);
      if (!user) return { status: 401, json: { code: 401, msg: "User not found", error_code: "user_not_found" } };
      const sid = claims.session_id ?? null;
      if (!sid) {   // a token without a session: a new session, as before
        const v = await asCaller({ role: "service_role" }, `update auth.mfa_factors set status = 'verified', updated_at = now() where id = ${lit(factorId)} and user_id = ${lit(claims.sub)} returning id`, sys);
        if (v.error || !v.text) return { status: 404, json: { code: 404, msg: "Factor not found", error_code: "mfa_factor_not_found" } };
        const s = await session({ ...user, factors: (user.factors ?? []).map((f) => (f.id === factorId ? { ...f, status: "verified" } : f)) }, "aal2", Math.floor(Date.now() / 1000)).catch(() => "error");
        return s === "error" ? { status: 500, json: { code: 500, msg: "The session could not be saved", error_code: "unexpected_failure" } } : { status: 200, json: s };
      }
      // the same session, now verified with a code: the factor and the session change together in one statement,
      // and only while that session still exists (an ended one changes nothing). In the session's turn; the session's
      // older refresh tokens end here, so none of them can bring back the level from before the code.
      return inTurn(sid, async () => {
        // the session row is locked first, so it can't end between the two changes
        const v = await asCaller({ role: "service_role" }, `with live as (select id from auth.sessions where id = ${lit(sid)} and user_id = ${lit(claims.sub)} for update),
          f as (update auth.mfa_factors set status = 'verified', updated_at = now() where id = ${lit(factorId)} and user_id = ${lit(claims.sub)} and exists (select 1 from live) returning id),
          s as (update auth.sessions set aal = 'aal2', refreshed_at = now(), updated_at = now() where id in (select id from live) and exists (select 1 from f) returning id)
          select (select count(*) from live) || ':' || (select count(*) from f) || (select count(*) from s)`, sys);
        if (v.error) return { status: 500, json: { code: 500, msg: "The session could not be saved", error_code: "unexpected_failure" } };
        if (v.text.startsWith("0:")) return { status: 401, json: { code: 401, msg: "Session not found", error_code: "session_not_found" } };
        if (v.text !== "1:11") return { status: 404, json: { code: 404, msg: "Factor not found", error_code: "mfa_factor_not_found" } };
        for (const [token, held] of REFRESH) if (held.sid === sid) REFRESH.delete(token);
        // the user in the answer as it is now: this factor verified (it was read before the change)
        const now = { ...user, factors: (user.factors ?? []).map((f) => (f.id === factorId ? { ...f, status: "verified" } : f)) };
        return { status: 200, json: issue(now, "aal2", Math.floor(Date.now() / 1000), sid) };
      });
    }
    return { status: 200, json: { all: [], totp: [], phone: [] } };
  }
  if (path === "/invite" || path === "/admin/users") {
    if (claims?.role !== "service_role") return { status: 403, json: { msg: "not allowed" } };
    if (req.method === "GET") {
      const r = await asCaller({ role: "service_role" }, `select coalesce(json_agg(id), '[]') from auth.users`, { preRequest: false, system: true });
      const users = await Promise.all(JSON.parse(r.text).map(userRow));
      return { status: 200, json: { users, aud: "authenticated" } };
    }
    const email = String(body?.email ?? "").toLowerCase();
    const r = await asCaller({ role: "service_role" }, `with x as (insert into auth.users (email, invited_at, raw_user_meta_data) values (${lit(email)}, now(), ${lit(JSON.stringify(body?.data ?? {}))}::jsonb) on conflict do nothing returning id)
      select coalesce((select id from x), (select id from auth.users where lower(email) = ${lit(email)}))`, { preRequest: false, system: true });
    const user = await userRow(r.text);
    if (user?.last_sign_in_at && path === "/invite") return { status: 422, json: { code: 422, msg: "A user with this email address has already been registered", error_code: "email_exists" } };
    return { status: 200, json: user };
  }
  // the server's view of a person's authenticators (auth.admin.mfa.listFactors / deleteFactor), ACC-30
  const adminFactors = /^\/admin\/users\/([0-9a-f-]{36})\/factors(?:\/([0-9a-f-]{36}))?$/.exec(path);
  if (adminFactors) {
    if (claims?.role !== "service_role") return { status: 403, json: { msg: "not allowed" } };
    const sys = { preRequest: false, system: true };
    if (req.method === "DELETE" && adminFactors[2]) {
      const d = await asCaller({ role: "service_role" }, `delete from auth.mfa_factors where id = ${lit(adminFactors[2])} and user_id = ${lit(adminFactors[1])} returning id`, sys);
      if (d.error) return { status: 500, json: { code: 500, msg: "The factor could not be deleted", error_code: "unexpected_failure" } };
      return d.text ? { status: 200, json: { id: d.text } } : { status: 404, json: { code: 404, msg: "Factor not found", error_code: "mfa_factor_not_found" } };
    }
    const r = await asCaller({ role: "service_role" }, `select coalesce(json_agg(json_build_object('id', id, 'status', status, 'factor_type', factor_type, 'friendly_name', friendly_name, 'created_at', created_at)), '[]') from auth.mfa_factors where user_id = ${lit(adminFactors[1])}`, sys);
    if (r.error) return { status: 500, json: { code: 500, msg: "The factors could not be read", error_code: "unexpected_failure" } };
    return { status: 200, json: JSON.parse(r.text || "[]") };
  }
  const adminUser = /^\/admin\/users\/([0-9a-f-]{36})$/.exec(path);
  if (adminUser) {
    if (claims?.role !== "service_role") return { status: 403, json: { msg: "not allowed" } };
    // a password change is recorded as a time only (every test password stays Test-pass-1)
    if (req.method === "PUT" && body?.password) {
      const w = await asCaller({ role: "service_role" }, `update auth.users set updated_at = now() where id = ${lit(adminUser[1])}`, { preRequest: false, system: true });
      if (w.error) return { status: 500, json: { code: 500, msg: "The password could not be updated", error_code: "unexpected_failure" } };
    }
    if (req.method === "PUT" && body?.user_metadata) await asCaller({ role: "service_role" }, `update auth.users set raw_user_meta_data = coalesce(raw_user_meta_data,'{}') || ${lit(JSON.stringify(body.user_metadata))}::jsonb where id = ${lit(adminUser[1])}`, { preRequest: false, system: true });
    const user = await userRow(adminUser[1]);
    return user ? { status: 200, json: user } : { status: 404, json: { msg: "User not found" } };
  }
  if (path === "/admin/generate_link") return { status: 200, json: { properties: { action_link: "http://localhost/test-link" }, user: null } };
  return { status: 404, json: { msg: `auth path not in the local stand-in: ${path}` } };
}

// Storage: kept in memory; enough for uploads to succeed and public URLs to load.
const files = new Map();
// Private buckets with row security (record-files) behave like Supabase Storage: every upload, signed link and delete
// runs as the caller against storage.objects, so the bucket's policies decide; bucket size and type limits apply.
const POLICY_BUCKETS = { "record-files": { max: 10485760, types: ["image/jpeg", "image/png", "image/webp", "image/heic", "application/pdf"] } };
const signed = new Map(); // token -> { key: "bucket/path", exp: ms } (links expire like Supabase signed URLs)
function multipartFile(raw, ctype) {
  const m = /boundary=(?:"([^"]+)"|([^;]+))/.exec(ctype ?? "");
  if (!m || !raw) return { bytes: raw, type: ctype };
  const boundary = Buffer.from(`--${m[1] ?? m[2]}`);
  let at = raw.indexOf(boundary), out = null;
  while (at !== -1) {
    const next = raw.indexOf(boundary, at + boundary.length);
    if (next === -1) break;
    const part = raw.subarray(at + boundary.length + 2, next - 2);
    const split = part.indexOf("\r\n\r\n");
    const head = part.subarray(0, split).toString();
    if (/filename=|name=""/.test(head)) out = { bytes: part.subarray(split + 4), type: /content-type:\s*([^\r\n]+)/i.exec(head)?.[1]?.trim() };
    at = next;
  }
  return out ?? { bytes: raw, type: ctype };
}
async function policyStorage(req, url, claims, raw) {
  const path = url.pathname.replace(/^\/storage\/v1/, "");
  const deny = (msg, status = 403) => ({ status, json: { statusCode: String(status), error: "Unauthorized", message: msg } });
  let m;
  if (req.method === "DELETE" && (m = /^\/object\/([^/]+)$/.exec(path))) {
    const names = JSON.parse(raw?.toString() || "{}").prefixes ?? [];
    const r = await asCaller(claims, `with d as (delete from storage.objects where bucket_id = ${lit(m[1])} and name = any(${lit(`{${names.map((n) => `"${n}"`).join(",")}}`)}::text[]) returning name) select coalesce(json_agg(name), '[]') from d`);
    if (r.error) return deny(r.error.message);
    const gone = JSON.parse(r.text || "[]"); gone.forEach((n) => files.delete(`${m[1]}/${n}`));
    return { status: 200, json: gone.map((name) => ({ name })) };
  }
  if (req.method === "POST" && (m = /^\/object\/sign\/([^/]+)$/.exec(path))) {
    const { paths = [], expiresIn = 60 } = JSON.parse(raw?.toString() || "{}");
    const out = [];
    for (const p of paths) {
      const r = await asCaller(claims, `select count(*) from storage.objects where bucket_id = ${lit(m[1])} and name = ${lit(p)}`);
      if (!r.error && r.text.trim() === "1") { const t = crypto.randomUUID(); signed.set(t, { key: `${m[1]}/${p}`, exp: Date.now() + expiresIn * 1000 }); out.push({ path: p, signedURL: `/object/sign/${m[1]}/${p}?token=${t}`, error: null }); }
      else out.push({ path: p, signedURL: null, error: "Object not found" });
    }
    return { status: 200, json: out };
  }
  if ((m = /^\/object\/sign\/([^/]+)\/(.+)$/.exec(path))) {
    const key = `${m[1]}/${decodeURIComponent(m[2])}`;
    if (req.method === "GET") {
      const t = url.searchParams.get("token");
      const s = signed.get(t);
      if (!s || s.key !== key || !files.has(key)) return deny("Invalid signature", 400);
      if (Date.now() > s.exp) return deny("Token has expired", 400);
      const f = files.get(key); return { status: 200, raw: f.body, type: f.type };
    }
    const r = await asCaller(claims, `select count(*) from storage.objects where bucket_id = ${lit(m[1])} and name = ${lit(decodeURIComponent(m[2]))}`);
    if (r.error || r.text.trim() !== "1") return deny("Object not found", 400);
    const t = crypto.randomUUID(); signed.set(t, { key, exp: Date.now() + (JSON.parse(raw?.toString() || "{}").expiresIn ?? 60) * 1000 });
    return { status: 200, json: { signedURL: `/object/sign/${key}?token=${t}` } };
  }
  // download with a sign-in (the server key, or a member the bucket's policies allow)
  if (req.method === "GET" && (m = /^\/object\/(?:authenticated\/)?([^/]+)\/(.+)$/.exec(path)) && !path.startsWith("/object/sign/")) {
    const key = `${m[1]}/${decodeURIComponent(m[2])}`;
    const r = await asCaller(claims, `select count(*) from storage.objects where bucket_id = ${lit(m[1])} and name = ${lit(decodeURIComponent(m[2]))}`);
    if (r.error || r.text.trim() !== "1" || !files.has(key)) return deny("Object not found", 400);
    const f = files.get(key); return { status: 200, raw: f.body, type: f.type };
  }
  if ((req.method === "POST" || req.method === "PUT") && (m = /^\/object\/([^/]+)\/(.+)$/.exec(path))) {
    const rule = POLICY_BUCKETS[m[1]], name = decodeURIComponent(m[2]);
    const file = multipartFile(raw, req.headers["content-type"]);
    if (!file.bytes?.length) return deny("Empty file", 400);
    if (file.bytes.length > rule.max) return deny("The object exceeded the maximum allowed size", 413);
    if (!rule.types.includes(file.type)) return deny(`mime type ${file.type} is not supported`, 415);
    const meta = JSON.stringify({ mimetype: file.type, size: file.bytes.length });
    const r = await asCaller(claims, `insert into storage.objects (bucket_id, name, owner, metadata) values (${lit(m[1])}, ${lit(name)}, auth.uid(), ${lit(meta)}::jsonb)`);
    if (r.error) return deny(`new row violates row-level security policy (${r.error.message})`);
    files.set(`${m[1]}/${name}`, { body: file.bytes, type: file.type });
    return { status: 200, json: { Key: `${m[1]}/${name}`, Id: crypto.randomUUID() } };
  }
  return { status: 404, json: { message: "storage path not in the local stand-in" } };
}
// Private buckets with no storage policies (business-documents): only the server key may create a signed upload
// link or list; the link's token alone allows that one upload, as on Supabase. Bucket size and type limits apply.
const SERVER_BUCKETS = { "business-documents": { max: 10485760, types: ["application/pdf", "image/jpeg", "image/png", "image/webp", "image/heic"] } };
const uploads = new Map(); // token -> { bucket, name, exp }
const reads = new Map();   // signed read token -> { key, exp }
function serverBucketStorage(req, url, claims, raw) {
  const path = url.pathname.replace(/^\/storage\/v1/, "");
  const deny = (msg, status = 403) => ({ status, json: { statusCode: String(status), error: "Unauthorized", message: msg } });
  let m;
  if ((m = /^\/object\/upload\/sign\/([^/]+)\/(.+)$/.exec(path))) {
    const bucket = m[1], name = decodeURIComponent(m[2]);
    if (req.method === "POST") {
      if (claims?.role !== "service_role") return deny("new row violates row-level security policy");
      const t = crypto.randomUUID(); uploads.set(t, { bucket, name, exp: Date.now() + 2 * 3600 * 1000 });
      return { status: 200, json: { url: `/object/upload/sign/${bucket}/${name}?token=${t}` } };
    }
    if (req.method === "PUT") {
      const u = uploads.get(url.searchParams.get("token"));
      if (!u || u.bucket !== bucket || u.name !== name || Date.now() > u.exp) return deny("Invalid signature", 400);
      if (files.has(`${bucket}/${name}`)) return deny("The resource already exists", 409);
      const rule = SERVER_BUCKETS[bucket], file = multipartFile(raw, req.headers["content-type"]);
      if (!file.bytes?.length) return deny("Empty file", 400);
      if (file.bytes.length > rule.max) return deny("The object exceeded the maximum allowed size", 413);
      if (!rule.types.includes(file.type)) return deny(`mime type ${file.type} is not supported`, 415);
      uploads.delete(url.searchParams.get("token"));
      files.set(`${bucket}/${name}`, { body: file.bytes, type: file.type });
      return { status: 200, json: { Key: `${bucket}/${name}` } };
    }
  }
  if (req.method === "POST" && (m = /^\/object\/list\/([^/]+)$/.exec(path))) {
    if (claims?.role !== "service_role") return { status: 200, json: [] };
    const { prefix = "", search = "" } = JSON.parse(raw?.toString() || "{}");
    const out = [];
    for (const [key, f] of files) {
      if (!key.startsWith(`${m[1]}/${prefix}/`)) continue;
      const name = key.slice(`${m[1]}/${prefix}/`.length);
      if (!name.includes("/") && name.includes(search)) out.push({ name, metadata: { size: f.body.length, mimetype: f.type } });
    }
    return { status: 200, json: out };
  }
  // a signed read link (createSignedUrl): made with the server key only; the link's token allows reading that file
  if ((m = /^\/object\/sign\/([^/]+)\/(.+)$/.exec(path))) {
    const key = `${m[1]}/${decodeURIComponent(m[2])}`;
    if (req.method === "POST") {
      if (claims?.role !== "service_role") return deny("new row violates row-level security policy");
      if (!files.has(key)) return { status: 400, json: { statusCode: "404", error: "not_found", message: "Object not found" } };
      const t = crypto.randomUUID(); reads.set(t, { key, exp: Date.now() + 3600 * 1000 });
      return { status: 200, json: { signedURL: `/object/sign/${m[1]}/${m[2]}?token=${t}` } };
    }
    if (req.method === "GET") {
      const r = reads.get(url.searchParams.get("token")), f = files.get(key);
      if (!r || r.key !== key || Date.now() > r.exp || !f) return deny("Invalid signature", 400);
      return { status: 200, raw: f.body, type: f.type };
    }
  }
  // reading a stored file: the server key only (a Range header reads just the first bytes, as the upload check does)
  if (req.method === "GET" && (m = /^\/object\/(?:authenticated\/)?([^/]+)\/(.+)$/.exec(path))) {
    if (claims?.role !== "service_role") return deny("Object not found", 400);
    const f = files.get(`${m[1]}/${decodeURIComponent(m[2])}`);
    if (!f) return { status: 404, json: { statusCode: "404", error: "not_found", message: "Object not found" } };
    const range = /^bytes=(\d+)-(\d+)$/.exec(req.headers.range ?? "");
    return { status: range ? 206 : 200, raw: range ? f.body.subarray(Number(range[1]), Number(range[2]) + 1) : f.body, type: f.type };
  }
  // anything else on a private bucket (an unsigned upload, a public or signed read, a delete) is refused, never stored
  return deny("This bucket is private");
}
async function storage(req, url, body, claims, raw) {
  const path = url.pathname.replace(/^\/storage\/v1/, "");
  const target = /^\/object\/(?:upload\/sign\/|list\/|sign\/|public\/|authenticated\/)?([^/?]+)/.exec(path)?.[1];
  if (target && SERVER_BUCKETS[target]) return serverBucketStorage(req, url, claims, raw);
  const bucket = /^\/object\/(?:sign\/|public\/|authenticated\/)?([^/?]+)/.exec(path)?.[1];
  if (bucket && POLICY_BUCKETS[bucket]) return policyStorage(req, url, claims, raw);
  const obj = /^\/object\/(?:public\/|sign\/|authenticated\/)?([^/]+)\/(.+)$/.exec(path);
  if (req.method === "POST" && path.startsWith("/object/list/")) return { status: 200, json: [] };
  if (req.method === "POST" && path.startsWith("/object/sign/")) return { status: 200, json: { signedURL: `/storage/v1${path.replace("/sign/", "/public/")}` } };
  if (obj && (req.method === "POST" || req.method === "PUT")) { files.set(`${obj[1]}/${obj[2]}`, { body, type: req.headers["content-type"] }); return { status: 200, json: { Key: `${obj[1]}/${obj[2]}`, Id: crypto.randomUUID() } }; }
  if (obj && req.method === "GET") { const f = files.get(`${obj[1]}/${obj[2]}`); return f ? { status: 200, raw: f.body, type: f.type } : { status: 404, json: { message: "Object not found" } }; }
  if (req.method === "DELETE") return { status: 200, json: [] };
  return { status: 404, json: { message: "storage path not in the local stand-in" } };
}

function read(req) {
  return new Promise((resolve) => { const chunks = []; req.on("data", (c) => chunks.push(c)); req.on("end", () => resolve(Buffer.concat(chunks))); });
}

export const log = [];
const TRUSTED_ORIGINS = new Set(["http://localhost:5199", "http://127.0.0.1:5199", "http://[::1]:5199"]);
const server = http.createServer(async (req, res) => {
  const cors = TRUSTED_ORIGINS.has(req.headers.origin) ? { "access-control-allow-origin": req.headers.origin, "access-control-allow-credentials": "true",
    "access-control-allow-headers": req.headers["access-control-request-headers"] ?? "*", "access-control-allow-methods": "GET,POST,PUT,PATCH,DELETE,HEAD,OPTIONS",
    "access-control-expose-headers": "content-range, x-total-count", "vary": "Origin" } : { "vary": "Origin" };
  if (req.method === "OPTIONS") { res.writeHead(204, cors); return res.end(); }
  const url = new URL(req.url, `http://${req.headers.host}`);
  const raw = await read(req);
  try {
    const fn = /^\/functions\/v1\/([a-z0-9-]+)/.exec(url.pathname);
    if (fn) {
      const port = FUNCTIONS[fn[1]];
      if (!port) { res.writeHead(404, { ...cors, "content-type": "application/json" }); return res.end(JSON.stringify({ error: `function ${fn[1]} is not running locally` })); }
      // a function is either a port (one Deno process per function) or "port/name" (the Supabase edge runtime, which
      // serves every function from one port by its folder name)
      const [fport, ...fname] = String(port).split("/");
      const r = await fetch(`http://127.0.0.1:${fport}${fname.length ? `/${fname.join("/")}` : ""}${url.pathname.replace(`/functions/v1/${fn[1]}`, "") || (fname.length ? "" : "/")}${url.search}`, {
        method: req.method, headers: Object.fromEntries(Object.entries(req.headers).filter(([k]) => !["host", "content-length", "connection"].includes(k))), body: ["GET", "HEAD"].includes(req.method) ? undefined : raw,
        redirect: "manual" }); // a function's redirect goes back to the browser, as on Supabase
      const text = Buffer.from(await r.arrayBuffer());
      res.writeHead(r.status, { ...cors, "content-type": r.headers.get("content-type") ?? "application/json", ...(r.headers.get("location") ? { location: r.headers.get("location") } : {}) });
      return res.end(text);
    }
    const bearer = String(req.headers.authorization ?? "").replace(/^Bearer\s+/i, "");
    const claims = bearer === SERVER_KEY || req.headers.apikey === SERVER_KEY && !bearer ? { role: "service_role" } : verify(bearer);
    const ctype = String(req.headers["content-type"] ?? "");
    const body = raw.length && ctype.includes("json") ? JSON.parse(raw.toString()) : raw.length ? raw : null;
    let out;
    if (url.pathname.startsWith("/rest/v1/")) out = await rest(req, url, claims, body);
    else if (url.pathname.startsWith("/auth/v1/")) out = await auth(req, url, claims, body);
    else if (url.pathname.startsWith("/storage/v1/")) out = await storage(req, url, body, claims, raw);
    else out = { status: 404, json: { message: "not found" } };
    log.push({ at: Date.now(), method: req.method, path: url.pathname, status: out.status, error: out.status >= 400 ? out.json : undefined });
    if (process.env.ZLOG && out.status >= 400) console.log(out.status, req.method, url.pathname + url.search, JSON.stringify(out.json).slice(0, 300));
    if (out.raw) { res.writeHead(out.status, { ...cors, "content-type": out.type ?? "application/octet-stream" }); return res.end(out.raw); }
    res.writeHead(out.status, { ...cors, "content-type": "application/json", ...(out.headers ?? {}) });
    res.end(out.status === 204 || out.head ? undefined : JSON.stringify(out.json ?? null));
  } catch (err) {
    if (process.env.ZLOG) console.log("500", req.method, url.pathname + url.search, err.message);
    res.writeHead(err.pgrst ? 400 : 500, { ...cors, "content-type": "application/json" });
    res.end(JSON.stringify({ code: err.pgrst ?? "LOCAL", message: err.message }));
  }
});
requireIsolated(PGH, PGP, DB);
http.createServer(server.listeners("request")[0])
  .on("error", (err) => {
    if (!["EADDRNOTAVAIL", "EAFNOSUPPORT"].includes(err.code)) console.error("IPv6 listener failed:", err);
  })
  .listen(PORT, "::1");
server.listen(PORT, "127.0.0.1", () => console.log(`local Supabase stand-in on http://localhost:${PORT} (database ${DB})`));
