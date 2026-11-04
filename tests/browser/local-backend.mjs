// A local stand-in for Supabase, for browser tests ONLY. It answers the calls the web app and the edge functions make
// (REST tables, RPC functions, auth, edge functions, storage) against an ISOLATED Postgres restored from
// sql/baseline (no production data). Every database call runs as the signed-in role with the caller's token claims, so
// row security, grants and the functions' own permission checks are the real ones. Auth is simplified: test users only,
// one shared test password, tokens signed with a local test secret. No email, text or call is ever sent.
//
// Usage: node tests/browser/local-backend.mjs     (env: ZDB=zella_ui ZPG_HOST ZPG_PORT PORT=54321)
// Not a full PostgREST: it covers the query shapes this app uses (select with embeds, eq/neq/gt/gte/lt/lte/like/ilike/
// is/in/cs/not, or=, order, limit/offset, count, single object, insert/upsert/update/delete, rpc).
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
    const p = spawn("psql", ["-h", PGH, "-p", PGP, "-U", "postgres", "-d", DB, "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1", "-v", "VERBOSITY=verbose"]);
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
function session(user, aal = "aal1") {
  const exp = Math.floor(Date.now() / 1000) + 3600;
  const claims = { sub: user.id, email: user.email, role: "authenticated", aud: "authenticated", aal, amr: [{ method: "password", timestamp: Math.floor(Date.now() / 1000) }], exp, session_id: crypto.randomUUID() };
  return { access_token: sign(claims), refresh_token: `r.${user.id}`, token_type: "bearer", expires_in: 3600, expires_at: exp, user };
}

async function auth(req, url, claims, body) {
  const path = url.pathname.replace(/^\/auth\/v1/, "");
  if (path === "/token") {
    let id = null;
    if (url.searchParams.get("grant_type") === "password") {
      if (body?.password !== TEST_PASSWORD) return { status: 400, json: { error: "invalid_grant", error_description: "Invalid login credentials", msg: "Invalid login credentials", code: "invalid_credentials" } };
      const r = await asCaller({ role: "service_role" }, `select id from auth.users where lower(email) = lower(${lit(body.email)})`, { preRequest: false, system: true });
      id = r.text || null;
    } else if (url.searchParams.get("grant_type") === "refresh_token") id = String(body?.refresh_token ?? "").replace(/^r\./, "");
    const user = id && (await userRow(id));
    if (!user) return { status: 400, json: { error: "invalid_grant", error_description: "Invalid login credentials", msg: "Invalid login credentials", code: "invalid_credentials" } };
    await asCaller({ role: "service_role" }, `update auth.users set last_sign_in_at = now() where id = ${lit(id)}`, { preRequest: false, system: true });
    return { status: 200, json: session(user) };
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
  if (path === "/factors" || path.startsWith("/factors")) return { status: 200, json: { all: [], totp: [], phone: [] } };
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
  const adminUser = /^\/admin\/users\/([0-9a-f-]{36})$/.exec(path);
  if (adminUser) {
    if (claims?.role !== "service_role") return { status: 403, json: { msg: "not allowed" } };
    if (req.method === "PUT" && body?.user_metadata) await asCaller({ role: "service_role" }, `update auth.users set raw_user_meta_data = coalesce(raw_user_meta_data,'{}') || ${lit(JSON.stringify(body.user_metadata))}::jsonb where id = ${lit(adminUser[1])}`, { preRequest: false, system: true });
    const user = await userRow(adminUser[1]);
    return user ? { status: 200, json: user } : { status: 404, json: { msg: "User not found" } };
  }
  if (path === "/admin/generate_link") return { status: 200, json: { properties: { action_link: "http://localhost/test-link" }, user: null } };
  return { status: 404, json: { msg: `auth path not in the local stand-in: ${path}` } };
}

// Storage: kept in memory; enough for uploads to succeed and public URLs to load.
const files = new Map();
async function storage(req, url, body) {
  const path = url.pathname.replace(/^\/storage\/v1/, "");
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
const server = http.createServer(async (req, res) => {
  const cors = { "access-control-allow-origin": req.headers.origin ?? "*", "access-control-allow-credentials": "true",
    "access-control-allow-headers": req.headers["access-control-request-headers"] ?? "*", "access-control-allow-methods": "GET,POST,PUT,PATCH,DELETE,HEAD,OPTIONS",
    "access-control-expose-headers": "content-range, x-total-count" };
  if (req.method === "OPTIONS") { res.writeHead(204, cors); return res.end(); }
  const url = new URL(req.url, `http://${req.headers.host}`);
  const raw = await read(req);
  try {
    const fn = /^\/functions\/v1\/([a-z0-9-]+)/.exec(url.pathname);
    if (fn) {
      const port = FUNCTIONS[fn[1]];
      if (!port) { res.writeHead(404, { ...cors, "content-type": "application/json" }); return res.end(JSON.stringify({ error: `function ${fn[1]} is not running locally` })); }
      const r = await fetch(`http://127.0.0.1:${port}${url.pathname.replace(`/functions/v1/${fn[1]}`, "") || "/"}${url.search}`, {
        method: req.method, headers: Object.fromEntries(Object.entries(req.headers).filter(([k]) => !["host", "content-length", "connection"].includes(k))), body: ["GET", "HEAD"].includes(req.method) ? undefined : raw });
      const text = Buffer.from(await r.arrayBuffer());
      res.writeHead(r.status, { ...cors, "content-type": r.headers.get("content-type") ?? "application/json" });
      return res.end(text);
    }
    const bearer = String(req.headers.authorization ?? "").replace(/^Bearer\s+/i, "");
    const claims = bearer === SERVER_KEY || req.headers.apikey === SERVER_KEY && !bearer ? { role: "service_role" } : verify(bearer);
    const ctype = String(req.headers["content-type"] ?? "");
    const body = raw.length && ctype.includes("json") ? JSON.parse(raw.toString()) : raw.length ? raw : null;
    let out;
    if (url.pathname.startsWith("/rest/v1/")) out = await rest(req, url, claims, body);
    else if (url.pathname.startsWith("/auth/v1/")) out = await auth(req, url, claims, body);
    else if (url.pathname.startsWith("/storage/v1/")) out = await storage(req, url, body);
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
server.listen(PORT, () => console.log(`local Supabase stand-in on http://localhost:${PORT} (database ${DB})`));
