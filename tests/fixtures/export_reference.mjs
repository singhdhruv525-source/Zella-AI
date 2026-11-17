#!/usr/bin/env node
// Builds tests/fixtures/reference_config.sql: production CONFIGURATION for local test databases, never customer data
// (UI-35, owner approved 16 Nov 2026). Read only, and only the allowlist below; anything else is refused.
//
//   node tests/fixtures/export_reference.mjs queries
//       Prints the exact read only SELECT for each allowlisted table. Run them on the project (read only) and save each
//       result, the JSON array the query returns, as <table>.json in one directory (outside the repository).
//   ZELLA_REFERENCE_PG='<conninfo>' node tests/fixtures/export_reference.mjs fetch <dir>
//       Runs those SELECTs itself with psql in a read only transaction and saves <table>.json files in <dir>.
//   node tests/fixtures/export_reference.mjs build <dir> [out.sql]
//       Checks every file against the allowlist (tables, columns, platform setting keys, no personal data, no links)
//       and writes the fixture (default tests/fixtures/reference_config.sql) in a fixed order.
//
// What is copied, and what is left out on purpose:
// - industries: id, name, slug, description, is_active. No business_id; no personal columns. created_at left out.
// - industry_modules: every column, with industry_id written as the industry slug (production ids differ from the
//   ids in a local test copy) and id/created_at left to the local defaults. No business_id; no personal columns.
// - industry_configurations: terminology, statuses, features (industry by slug; id and timestamps local).
// - industry_automation_defaults: every column (industry by slug).
// - message_templates: platform templates only (business_id is null). business_id is never exported. created_by is
//   LEFT OUT: it holds the user id of the person who wrote the template (a person, so personal data). id and
//   created_at are local. Only active templates (production has no other kind).
// - platform_settings: ONLY the keys in SETTING_KEYS (an explicit allowlist, so a new setting is never exported until
//   someone adds it here after checking its value). As a second check, keys ending in _url, email_from_address,
//   sms_from_number, keys starting with vapi_ and (by the rulebook: no model ids in code or fixtures) keys ending in
//   _model or _model_multilingual are refused even if listed. Every key ending in _live, and n8n_dispatch_enabled, is
//   written as false whatever production holds.
import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const SETTING_EXCLUDED = (k) => /_url$/.test(k) || /^vapi_/.test(k) || /_model$/.test(k) || /_model_multilingual$/.test(k)
  || k === "email_from_address" || k === "sms_from_number";
const SETTING_FORCED_FALSE = (k) => /_live$/.test(k) || k === "n8n_dispatch_enabled";
// The platform settings the fixture may hold (explicit allowlist; checked against production's values on 16 Nov 2026).
export const SETTING_KEYS = Object.freeze([
  "ai_low_confidence_questions", "calendar_sync_live", "call_intel_live", "call_intel_monthly_limit",
  "call_reconcile_live", "call_usage_missing_duration_hours", "call_usage_policy", "call_usage_rules", "calls_live",
  "email_live", "invitation_reminder_hours", "knowledge_ai_live", "knowledge_repeat_threshold",
  "missed_call_max_seconds", "n8n_dispatch_enabled", "payment_auto_suspend", "payment_grace_days",
  "payment_suspend_after_days", "response_sample_rate", "response_time_minutes", "retention_days", "review_ai_live",
  "reviews_live", "setup_incomplete_after_days", "sms_alerts_default_on", "sms_live", "sms_marketing_allowed",
  "spam_ai_live", "spam_ai_monthly_limit", "spam_defaults", "spam_workflow_live", "task_escalate_hours",
  "task_overdue_grace_minutes", "team_summary_hour", "transfer_failure_threshold", "trial_notice_days",
  "usage_enforcement", "voice_llm_provider", "voice_max_call_seconds", "voice_stt_language", "voice_stt_provider",
  "voice_tts_choices", "voice_tts_provider", "voice_tts_voice_id", "website_crawl_live",
]);
const SETTING_EXCLUDED_SQL = `key in (${SETTING_KEYS.map((k) => `'${k}'`).join(", ")}) and key !~ '_url$' and key !~ '^vapi_' and key !~ '_model$' and key !~ '_model_multilingual$' and key not in ('email_from_address', 'sms_from_number')`;

// The allowlist. columns: exactly the keys each exported row has, no more, no fewer.
export const ALLOW = {
  industries: {
    columns: ["id", "name", "slug", "description", "is_active"],
    query: "select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'slug', slug, 'description', description, 'is_active', is_active) order by slug), '[]') from public.industries",
  },
  industry_modules: {
    columns: ["industry_slug", "slug", "name", "description", "is_active"],
    query: "select coalesce(jsonb_agg(jsonb_build_object('industry_slug', i.slug, 'slug', m.slug, 'name', m.name, 'description', m.description, 'is_active', m.is_active) order by i.slug, m.slug), '[]') from public.industry_modules m join public.industries i on i.id = m.industry_id",
  },
  industry_configurations: {
    columns: ["industry_slug", "terminology", "statuses", "features"],
    query: "select coalesce(jsonb_agg(jsonb_build_object('industry_slug', i.slug, 'terminology', c.terminology, 'statuses', c.statuses, 'features', c.features) order by i.slug), '[]') from public.industry_configurations c join public.industries i on i.id = c.industry_id",
  },
  industry_automation_defaults: {
    columns: ["industry_slug", "trigger_type", "enabled", "config"],
    query: "select coalesce(jsonb_agg(jsonb_build_object('industry_slug', i.slug, 'trigger_type', d.trigger_type, 'enabled', d.enabled, 'config', d.config) order by i.slug, d.trigger_type), '[]') from public.industry_automation_defaults d join public.industries i on i.id = d.industry_id",
  },
  message_templates: {
    columns: ["industry_slug", "key", "channel", "purpose", "locale", "subject", "body", "version", "status"],
    query: "select coalesce(jsonb_agg(jsonb_build_object('industry_slug', i.slug, 'key', t.key, 'channel', t.channel, 'purpose', t.purpose, 'locale', t.locale, 'subject', t.subject, 'body', t.body, 'version', t.version, 'status', t.status) order by t.key, t.channel, i.slug nulls first, t.locale), '[]') from public.message_templates t left join public.industries i on i.id = t.industry_id where t.business_id is null",
  },
  platform_settings: {
    columns: ["key", "value"],
    query: `select coalesce(jsonb_agg(jsonb_build_object('key', key, 'value', value) order by key), '[]') from public.platform_settings where ${SETTING_EXCLUDED_SQL}`,
  },
};

// Personal data and links: refused anywhere in an exported value.
const EMAIL = /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/;
const URL_LIKE = /\b(?:https?|ftp|wss?):\/\/|\bwww\.|\b[a-z0-9-]+\.(?:com|net|org|io|co|app|dev|ai|uk|us|test|supabase|cloud)\b/i;
const PHONE = /\+?\d[\d\s().-]{7,}\d/g;
const UUID = /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi;
export function personalDataIn(text) {
  const s = String(text).replace(UUID, "");
  if (EMAIL.test(s)) return "an email address";
  if (URL_LIKE.test(s)) return "a link";
  if ((s.match(PHONE) ?? []).some((m) => m.replace(/\D/g, "").length >= 7)) return "a phone number";
  return null;
}

function refuse(msg) { throw new Error(`REFUSED: ${msg}`); }
function walkStrings(v, fn, path) {
  if (typeof v === "string") fn(v, path);
  else if (Array.isArray(v)) v.forEach((x, i) => walkStrings(x, fn, `${path}[${i}]`));
  else if (v && typeof v === "object") for (const [k, x] of Object.entries(v)) { fn(k, `${path}.${k} (key)`); walkStrings(x, fn, `${path}.${k}`); }
}

export function validate(tables) {
  for (const t of Object.keys(tables)) if (!ALLOW[t]) refuse(`'${t}' is not on the allowlist`);
  for (const t of Object.keys(ALLOW)) if (!Array.isArray(tables[t])) refuse(`${t}: missing or not a JSON array`);
  for (const [t, rows] of Object.entries(tables)) {
    const want = [...ALLOW[t].columns].sort().join(",");
    rows.forEach((r, i) => {
      if (!r || typeof r !== "object" || Array.isArray(r)) refuse(`${t}[${i}] is not a row object`);
      const have = Object.keys(r).sort().join(",");
      if (have !== want) refuse(`${t}[${i}] has columns (${have}); only (${want}) are allowed`);
      walkStrings(r, (s, p) => { const why = personalDataIn(s); if (why) refuse(`${t}[${i}]${p} holds ${why}`); }, "");
    });
  }
  const slugs = new Set(tables.industries.map((r) => r.slug));
  for (const t of ["industry_modules", "industry_configurations", "industry_automation_defaults", "message_templates"])
    for (const r of tables[t]) if (r.industry_slug !== null && !slugs.has(r.industry_slug)) refuse(`${t}: unknown industry '${r.industry_slug}'`);
  for (const r of tables.industries) if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(r.id)) refuse(`industries: '${r.id}' is not an id`);
  for (const r of tables.message_templates) if (r.status !== "active") refuse(`message_templates: only active platform templates are exported (${r.key} is ${r.status})`);
  for (const r of tables.platform_settings) {
    if (!SETTING_KEYS.includes(r.key)) refuse(`platform_settings: '${r.key}' is not on the settings allowlist`);
    if (SETTING_EXCLUDED(r.key)) refuse(`platform_settings: '${r.key}' is an excluded setting (a link, sender, provider id or model)`);
  }
}

// SQL literals
const canon = (v) => Array.isArray(v) ? v.map(canon) : v && typeof v === "object" ? Object.fromEntries(Object.keys(v).sort().map((k) => [k, canon(v[k])])) : v;
const str = (s) => s === null ? "null" : /[\n\r\t\\]/.test(s)
  ? `E'${s.replace(/\\/g, "\\\\").replace(/'/g, "''").replace(/\n/g, "\\n").replace(/\r/g, "\\r").replace(/\t/g, "\\t")}'`
  : `'${s.replace(/'/g, "''")}'`;
const jsonb = (v) => `${str(JSON.stringify(canon(v)))}::jsonb`;
const bool = (b) => { if (typeof b !== "boolean") refuse(`'${b}' is not true or false`); return String(b); };
const int = (n) => { if (!Number.isInteger(n)) refuse(`'${n}' is not a whole number`); return String(n); };
const cmp = (...keys) => (a, b) => { for (const k of keys) { const x = a[k] ?? "", y = b[k] ?? ""; if (x < y) return -1; if (x > y) return 1; } return 0; };

export function buildSql(tables) {
  validate(tables);
  const T = Object.fromEntries(Object.entries(tables).map(([k, v]) => [k, [...v]]));
  T.industries.sort(cmp("slug"));
  T.industry_modules.sort(cmp("industry_slug", "slug"));
  T.industry_configurations.sort(cmp("industry_slug"));
  T.industry_automation_defaults.sort(cmp("industry_slug", "trigger_type"));
  T.message_templates.sort(cmp("key", "channel", "industry_slug", "locale"));
  T.platform_settings.sort(cmp("key"));
  const settings = T.platform_settings.map((r) => ({ key: r.key, value: SETTING_FORCED_FALSE(r.key) ? false : r.value }));
  const L = [];
  L.push("-- Zella Voice reference CONFIGURATION copied read only from production (UI-35). Not customer data.",
    "-- Generated by tests/fixtures/export_reference.mjs; do not edit by hand. Load it with tests/fixtures/load_reference.sh",
    "-- (isolated test server only). Idempotent: run it again and nothing changes.",
    `-- Rows: ${T.industries.length} industries, ${T.industry_modules.length} modules, ${T.industry_configurations.length} configurations, ${T.industry_automation_defaults.length} automation defaults, ${T.message_templates.length} platform templates, ${settings.length} platform settings.`,
    "-- Every *_live setting and n8n_dispatch_enabled is false here, whatever production holds.",
    "begin;", "");
  L.push("insert into public.industries (id, name, slug, description, is_active) values");
  L.push(T.industries.map((r) => `  (${str(r.id)}, ${str(r.name)}, ${str(r.slug)}, ${str(r.description)}, ${bool(r.is_active)})`).join(",\n"));
  L.push("on conflict (slug) do update set name = excluded.name, description = excluded.description, is_active = excluded.is_active;", "");
  L.push("insert into public.industry_modules (industry_id, slug, name, description, is_active)",
    "select i.id, v.slug, v.name, v.description, v.is_active from (values");
  L.push(T.industry_modules.map((r) => `  (${str(r.industry_slug)}, ${str(r.slug)}, ${str(r.name)}, ${str(r.description)}, ${bool(r.is_active)})`).join(",\n"));
  L.push(") v (industry_slug, slug, name, description, is_active) join public.industries i on i.slug = v.industry_slug",
    "on conflict (industry_id, slug) do update set name = excluded.name, description = excluded.description, is_active = excluded.is_active;", "");
  L.push("insert into public.industry_configurations (industry_id, terminology, statuses, features)",
    "select i.id, v.terminology, v.statuses, v.features from (values");
  L.push(T.industry_configurations.map((r) => `  (${str(r.industry_slug)},\n   ${jsonb(r.terminology)},\n   ${jsonb(r.statuses)},\n   ${jsonb(r.features)})`).join(",\n"));
  L.push(") v (industry_slug, terminology, statuses, features) join public.industries i on i.slug = v.industry_slug",
    "on conflict (industry_id) do update set terminology = excluded.terminology, statuses = excluded.statuses, features = excluded.features,",
    "  updated_at = case when (industry_configurations.terminology, industry_configurations.statuses, industry_configurations.features)",
    "    is not distinct from (excluded.terminology, excluded.statuses, excluded.features) then industry_configurations.updated_at else now() end;", "");
  L.push("insert into public.industry_automation_defaults (industry_id, trigger_type, enabled, config)",
    "select i.id, v.trigger_type, v.enabled, v.config from (values");
  L.push(T.industry_automation_defaults.map((r) => `  (${str(r.industry_slug)}, ${str(r.trigger_type)}, ${bool(r.enabled)}, ${jsonb(r.config)})`).join(",\n"));
  L.push(") v (industry_slug, trigger_type, enabled, config) join public.industries i on i.slug = v.industry_slug",
    "on conflict (industry_id, trigger_type) do update set enabled = excluded.enabled, config = excluded.config;", "");
  L.push("-- platform templates only: nothing here sets a business, so every row is a platform row",
    "insert into public.message_templates (industry_id, key, channel, purpose, locale, subject, body, version, status)",
    "select i.id, v.key, v.channel, v.purpose, v.locale, v.subject, v.body, v.version, v.status from (values");
  L.push(T.message_templates.map((r) => `  (${str(r.industry_slug)}, ${str(r.key)}, ${str(r.channel)}, ${str(r.purpose)}, ${str(r.locale)},\n   ${str(r.subject)},\n   ${str(r.body)}, ${int(r.version)}, ${str(r.status)})`).join(",\n"));
  L.push(") v (industry_slug, key, channel, purpose, locale, subject, body, version, status) left join public.industries i on i.slug = v.industry_slug",
    "on conflict (coalesce(business_id, '00000000-0000-0000-0000-000000000000'::uuid), coalesce(industry_id, '00000000-0000-0000-0000-000000000000'::uuid), key, channel, locale) where status = 'active'",
    "do update set purpose = excluded.purpose, subject = excluded.subject, body = excluded.body, version = excluded.version;", "");
  L.push("insert into public.platform_settings (key, value) values");
  L.push(settings.map((r) => `  (${str(r.key)}, ${jsonb(r.value)})`).join(",\n"));
  L.push("on conflict (key) do update set value = excluded.value,",
    "  updated_at = case when platform_settings.value = excluded.value then platform_settings.updated_at else now() end;", "");
  L.push("-- a test database never sends anything: every live switch off, including ones set before this file ran",
    "update public.platform_settings set value = 'false'::jsonb, updated_at = now()",
    "where (key like '%\\_live' or key = 'n8n_dispatch_enabled') and value is distinct from 'false'::jsonb;", "", "commit;", "");
  return L.join("\n");
}

function readDir(dir) {
  const tables = {};
  for (const f of readdirSync(dir).filter((f) => f.endsWith(".json")).sort()) {
    const t = f.slice(0, -5);
    if (!ALLOW[t]) refuse(`${f}: '${t}' is not on the allowlist`);
    tables[t] = JSON.parse(readFileSync(join(dir, f), "utf8"));
  }
  return tables;
}

function fetchAll(dir) {
  const conn = process.env.ZELLA_REFERENCE_PG;
  if (!conn) refuse("set ZELLA_REFERENCE_PG to a read only connection");
  mkdirSync(dir, { recursive: true });
  for (const [t, { query }] of Object.entries(ALLOW)) {
    // read only at the session level and inside the transaction: a write is refused by the server, not by trust
    const out = execFileSync("psql", ["-X", "-At", "-v", "ON_ERROR_STOP=1", "-d", conn, "-c", "begin transaction read only", "-c", query, "-c", "rollback"],
      { env: { ...process.env, PGOPTIONS: "-c default_transaction_read_only=on" }, stdio: ["ignore", "pipe", "inherit"] }).toString();
    const json = out.split("\n").find((l) => l.startsWith("["));
    if (!json) refuse(`${t}: no result`);
    writeFileSync(join(dir, `${t}.json`), json + "\n");
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [cmd, dir, out] = process.argv.slice(2);
  try {
    if (cmd === "queries") for (const [t, { query }] of Object.entries(ALLOW)) console.log(`-- ${t}\n${query};\n`);
    else if (cmd === "fetch" && dir) fetchAll(dir);
    else if (cmd === "build" && dir) {
      const file = out ?? join(HERE, "reference_config.sql");
      writeFileSync(file, buildSql(readDir(dir)));
      console.log(`wrote ${file}`);
    } else { console.error("usage: export_reference.mjs queries | fetch <dir> | build <dir> [out.sql]"); process.exit(2); }
  } catch (e) { console.error(e.message); process.exit(1); }
}
