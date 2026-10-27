// Latency of the synchronous path in staging: voice-rules -> mock-rest -> local Postgres. Prints p50 / p95 / max in ms.
// IMPORTANT: mock-rest starts a new psql process per database call, so "db" numbers include that overhead (measured
// separately as "rpc overhead"); real PostgREST keeps connections open. Use this to compare request shapes, not as a
// production prediction.
import { readFileSync } from 'node:fs';
import { P, sql, callA } from './vapi-client.mjs';
const N = Number(process.env.BENCH_N || 30);
const A = 'aaaaaaaa-0000-4000-8000-000000000001';
const q = (xs) => { const s = [...xs].sort((a, b) => a - b); const at = (p) => s[Math.min(s.length - 1, Math.floor(p * s.length))]; return { p50: at(0.5), p95: at(0.95), max: s[s.length - 1] }; };
const fmt = (o) => `p50 ${o.p50}  p95 ${o.p95}  max ${o.max}`;
sql(readFileSync(new URL('./fixture.sql', import.meta.url), 'utf8'));
sql(`insert into business_phone_numbers (business_id, e164, vapi_phone_number_id) values ('${A}', '+15550001000', 'pn-A');
  insert into ai_agents (id, business_id, name, agent_type, is_default) values ('a0000000-0000-4000-8000-00000000000a', '${A}', 'R', 'receptionist', true);
  insert into ai_agent_configs (agent_id, escalation_rules) values ('a0000000-0000-4000-8000-00000000000a', '{"transfer_number": "+15550101111", "transfer_open_hours_only": false}');`);
const tc = (id, name, args = {}) => ({ id, type: 'function', function: { name, arguments: JSON.stringify(args) } });
const out = {};
async function measure(label, mk) {
  const total = [], parts = {}; let failed = 0, errors = 0;
  for (let i = 0; i < N; i++) {
    const t0 = performance.now();
    const r = await P(mk(i));
    const body = await r.json();
    total.push(Math.round(performance.now() - t0));
    if (r.status !== 200) errors++;
    failed += (body.results || []).filter((x) => x.error).length;
    for (const m of (r.headers.get('server-timing') || '').split(',')) { const [k, v] = m.trim().split(';dur='); if (v !== undefined && !['calls', 'failed'].includes(k)) (parts[k] ||= []).push(Number(v)); }
  }
  out[label] = { client_total: q(total), ...Object.fromEntries(Object.entries(parts).map(([k, v]) => [k, q(v)])), non_200: errors, tool_errors: failed };
  console.log(`\n${label} (n=${N})\n  client total  ${fmt(q(total))}\n` + Object.entries(parts).map(([k, v]) => `  ${k.padEnd(12)}  ${fmt(q(v))}`).join('\n') + `\n  non-200: ${errors}, tool error answers: ${failed}`);
}
// baseline: one database call through mock-rest without the function
const base = [];
for (let i = 0; i < N; i++) { const t0 = performance.now(); await fetch('http://127.0.0.1:54400/rest/v1/rpc/zella_digits', { method: 'POST', body: '{"p":"+15551230001"}' }); base.push(Math.round(performance.now() - t0)); }
console.log(`rpc overhead (mock-rest + new psql process, trivial function) ${fmt(q(base))}`);
const rulesOnly = process.env.BENCH_ONLY === 'rules';
await measure('call_rules x1', (i) => ({ message: { type: 'tool-calls', call: callA('bench-r1-' + i), toolCallList: [{ id: 'a', name: 'call_rules', arguments: { action: 'rules' } }] } }));
await measure('call_rules x3', (i) => ({ message: { type: 'tool-calls', call: callA('bench-r3-' + i), toolCallList: ['a', 'b', 'c'].map((id) => ({ id, name: 'call_rules', arguments: { action: 'rules' } })) } }));
if (rulesOnly) process.exit(0);
await measure('status-update', (i) => ({ message: { type: 'status-update', status: 'ringing', timestamp: Date.now() + i, call: callA('bench-s-' + i) } }));
await measure('1 tool (lookup_caller)', (i) => ({ message: { type: 'tool-calls', call: callA('bench-1-' + i), toolCallList: [tc('a', 'lookup_caller')] } }));
await measure('3 tools (lookup_caller, check_open_hours, check_availability)', (i) => ({ message: { type: 'tool-calls', call: callA('bench-3-' + i),
  toolCallList: [tc('a', 'lookup_caller'), tc('b', 'check_open_hours'), tc('c', 'check_availability', { date: '2026-11-03', days: 1 })] } }));
const slots = JSON.parse(sql(`select (public.zella_ai_tool(null, '${A}', 'check_availability', '{"date": "2026-11-02", "days": 7}') -> 'slots')::text`) || '[]');
const NB = Math.min(N, 20, slots.length);
const book = [];
for (let i = 0; i < NB; i++) {
  const t0 = performance.now();
  const r = await (await P({ message: { type: 'tool-calls', call: callA('bench-b-' + i, { customer: { number: '+1555888' + String(i).padStart(4, '0') } }),
    toolCallList: [tc('k', 'book_appointment', { start: slots[i].start, first_name: 'B' + i, phone: '+1555888' + String(i).padStart(4, '0'), confirmed: true })] } })).json();
  book.push({ ms: Math.round(performance.now() - t0), ok: JSON.parse(r.results[0].result || '{}').status === 'booked' });
}
console.log(`\nbook_appointment, distinct times (n=${NB})\n  client total  ${fmt(q(book.map((b) => b.ms)))}\n  booked: ${book.filter((b) => b.ok).length}/${NB}`);
// database time alone (inside Postgres: no HTTP, no psql start-up), N times each, including a fully signed auth check
const dbt = sql(`create temp table t (k text, ms numeric);
do $$ declare t0 timestamptz; r jsonb; v text; k text := (select decrypted_secret from vault.decrypted_secrets where name = 'zella_vapi_hmac_secret'); ts text; body text; begin
  for i in 1..${N} loop
    body := '{"message":{"type":"tool-calls","n":' || i || '}}'; ts := extract(epoch from now())::bigint::text;
    t0 := clock_timestamp();
    v := public.zella_vapi_authenticate(body, jsonb_build_object('x-timestamp', ts, 'x-signature', encode(extensions.hmac(convert_to(ts || '.' || body, 'utf8'), convert_to(k, 'utf8'), 'sha256'), 'hex')));
    insert into t values ('zella_vapi_authenticate (signed, ' || v || ')', extract(epoch from clock_timestamp() - t0) * 1000);
    t0 := clock_timestamp(); v := public.zella_business_for_number('+15550001000', 'pn-A', null)::text; insert into t values ('zella_business_for_number', extract(epoch from clock_timestamp() - t0) * 1000);
    t0 := clock_timestamp(); r := public.zella_ai_tool('benchdb-' || i, '${A}', 'lookup_caller', '{"caller_number": "+15551230001"}'); insert into t values ('zella_ai_tool lookup_caller', extract(epoch from clock_timestamp() - t0) * 1000);
    t0 := clock_timestamp(); r := public.zella_ai_tool('benchdb-' || i, '${A}', 'check_availability', '{"date": "2026-11-03", "days": 1}'); insert into t values ('zella_ai_tool check_availability', extract(epoch from clock_timestamp() - t0) * 1000);
  end loop; end $$;
select k || '|' || round((percentile_cont(0.5) within group (order by ms))::numeric, 2) || '|' || round((percentile_cont(0.95) within group (order by ms))::numeric, 2) || '|' || round(max(ms), 2) from t group by k order by k;`);
console.log('\ninside Postgres (ms)            p50 | p95 | max');
for (const l of dbt.split('\n').filter((x) => x.includes('|'))) { const [k, a, b, c] = l.split('|'); console.log(`  ${k.padEnd(48)} ${a} | ${b} | ${c}`); }
