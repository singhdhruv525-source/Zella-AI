#!/usr/bin/env node
// Guard for tests/fixtures/reference_config.sql (UI-35): fails if the committed fixture holds an email address, a phone
// number, a link, a business id, or a live switch that is on. Also checks the exporter refuses what is not allowlisted.
//   node tests/fixtures/reference_guard.mjs [fixture.sql]
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { ALLOW, buildSql, personalDataIn } from "./export_reference.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const file = process.argv[2] ?? join(HERE, "reference_config.sql");
const sql = readFileSync(file, "utf8");
let fails = 0;
const ok = (m) => console.log(`PASS ${m}`), bad = (m) => { console.log(`FAIL ${m}`); fails++; };
const check = (cond, m) => (cond ? ok(m) : bad(m));

// 1. no email address, phone number or link anywhere (comments included)
const lines = sql.split("\n");
const hits = lines.map((l, i) => [i + 1, personalDataIn(l)]).filter(([, why]) => why);
check(hits.length === 0, `no email address, phone number or link in the fixture${hits.length ? `: ${hits.slice(0, 5).map(([n, w]) => `line ${n} ${w}`).join("; ")}` : ""}`);
// the patterns themselves catch what they should (a guard that never fires proves nothing)
for (const [s, want] of [["owner@example.com", "an email address"], ["call +44 20 7946 0958", "a phone number"], ["(555) 010-4477", "a phone number"],
  ["see https://zella.example", "a link"], ["www.zella", "a link"], ["{{business}} at {{date}}", null], ["Please arrive 10 minutes early", null]])
  check(personalDataIn(s) === want, `detector: '${s}' -> ${want ?? "clean"}`);

// 2. no business id: business_id appears only in the conflict target of the platform template insert, never as a value
const bizUses = [...sql.matchAll(/business_id/g)].length;
const allowedUse = [...sql.matchAll(/coalesce\(business_id, '00000000-0000-0000-0000-000000000000'::uuid\)/g)].length;
check(bizUses === allowedUse && allowedUse <= 1, `business_id appears only as the platform template conflict target (${bizUses} use)`);
// every id in the file is either the all zero placeholder or one of the industry ids the file itself inserts
const industryBlock = sql.slice(sql.indexOf("insert into public.industries"), sql.indexOf("on conflict (slug)"));
const industryIds = new Set(industryBlock.match(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/g) ?? []);
const stray = (sql.match(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi) ?? [])
  .filter((u) => u !== "00000000-0000-0000-0000-000000000000" && !industryIds.has(u));
check(stray.length === 0 && industryIds.size === 28, `the only ids are the 28 industry ids (stray: ${stray.length})`);
check(!/created_by/.test(sql), "no created_by (a person's user id) in the fixture");

// 3. live switches all off; excluded settings absent
const setting = (k) => (sql.match(new RegExp(`\\('${k}', '([^']*)'::jsonb\\)`)) ?? [])[1];
const liveKeys = [...sql.matchAll(/\('([a-z0-9_]+_live|n8n_dispatch_enabled)', '([^']*)'::jsonb\)/g)];
check(liveKeys.length > 0 && liveKeys.every((m) => m[2] === "false"), `every _live setting and n8n_dispatch_enabled is false (${liveKeys.length})`);
check(setting("n8n_dispatch_enabled") === "false", "n8n_dispatch_enabled is false");
const settingKeys = [...sql.slice(sql.indexOf("insert into public.platform_settings")).matchAll(/^\s+\('([a-z0-9_]+)', /gm)].map((m) => m[1]);
check(!settingKeys.some((k) => /_url$|^vapi_|_model$|_model_multilingual$/.test(k) || ["email_from_address", "sms_from_number"].includes(k)),
  `no excluded setting (${settingKeys.length} settings)`);

// 4. deterministic: rebuilding from the rows in the file would sort the same way (industries by slug)
const slugs = [...industryBlock.matchAll(/', '[^']*', '([a-z-]+)', /g)].map((m) => m[1]);
check(slugs.length === 28 && slugs.join() === [...slugs].sort().join(), "industries are in slug order");

// 5. the exporter refuses anything not on the allowlist
const base = () => Object.fromEntries(Object.keys(ALLOW).map((t) => [t, []]));
const refuses = (tables, why) => { try { buildSql(tables); bad(`exporter accepted ${why}`); } catch (e) { check(/^REFUSED/.test(e.message), `exporter refuses ${why}`); } };
refuses({ ...base(), businesses: [] }, "a table not on the allowlist");
refuses({ ...base(), message_templates: [{ industry_slug: null, key: "k", channel: "sms", purpose: "transactional", locale: "en-US", subject: null, body: "b", version: 1, status: "active", business_id: "00000000-0000-0000-0000-000000000001" }] }, "a business_id column");
refuses({ ...base(), message_templates: [{ industry_slug: null, key: "k", channel: "sms", purpose: "transactional", locale: "en-US", subject: null, body: "b", version: 1, status: "active", created_by: null }] }, "a created_by column");
for (const k of ["app_base_url", "email_from_address", "sms_from_number", "vapi_assistant_id", "voice_tts_model"])
  refuses({ ...base(), platform_settings: [{ key: k, value: "x" }] }, `the setting ${k}`);
refuses({ ...base(), message_templates: [{ industry_slug: null, key: "k", channel: "sms", purpose: "transactional", locale: "en-US", subject: null, body: "Call 07700 900123", version: 1, status: "active" }] }, "a phone number in a template");
refuses({ ...base(), industries: [{ id: "8d0c2872-54b3-4393-8642-1530c571fa94", name: "A", slug: "a", description: "mail owner@example.com", is_active: true }] }, "an email address in a description");
const forced = buildSql({ ...base(), platform_settings: [{ key: "sms_live", value: true }, { key: "n8n_dispatch_enabled", value: true }] });
check(/\('sms_live', 'false'::jsonb\)/.test(forced) && /\('n8n_dispatch_enabled', 'false'::jsonb\)/.test(forced), "exporter writes live switches as false even when the source has them on");

console.log(fails ? `${fails} FAILED` : "all passed");
process.exit(fails ? 1 : 0);
