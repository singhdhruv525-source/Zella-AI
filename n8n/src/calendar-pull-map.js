// Zella Voice - Calendar Sync: turn the calendar's events into busy blocks. Cancelled, "free" and Zella-made events are left out.
const plan = $('Plan pull').item.json;
const outlook = plan.provider === 'outlook';
const name = outlook ? 'microsoft' : 'google';
const fail = (error, fatal) => ({ json: { events: null, error: { p_connection_id: plan.connection_id, p_error: String(error).slice(0, 80), p_fatal: !!fatal } } });
if (!plan.connection_id || !plan.url) return { json: { events: null, error: null } };
let tok = null;
for (const node of outlook ? ['Get Microsoft pull token'] : ['Get pull token']) { try { tok = $(node).item.json; } catch (e) { tok = null; } }
const tb = tok && tok.body && typeof tok.body === 'object' ? tok.body : {};
if (!tb.access_token) { const err = typeof tb.error === 'string' ? tb.error.replace(/[^a-z_]/gi, '').slice(0, 30) : 'failed'; return fail(name + '_token_' + err, err === 'invalid_grant'); }
const status = Number($json.statusCode);
const b = $json.body && typeof $json.body === 'object' ? $json.body : {};
const list = outlook ? b.value : b.items;
if (!(status >= 200 && status < 300) || !Array.isArray(list)) return fail(name + '_' + (status || 'no_answer'), status === 404);
let state = { pages: [], seen: [] };
try { state = $('Pull page').item.json; } catch {}
const marker = outlook ? b['@odata.nextLink'] : b.nextPageToken;
let next = null;
if (marker) {
  try {
    const url = new URL(outlook ? marker : plan.url);
    if (!outlook) url.searchParams.set('pageToken', marker);
    const base = new URL(plan.url);
    if (url.origin !== base.origin || url.pathname !== base.pathname || url.username || url.password || url.hash) throw new Error();
    next = url.toString();
    if (state.seen.includes(next) || next === state.url) throw new Error();
  } catch { return fail(name + '_bad_pagination', false); }
}
const events = [];
for (const e of list) {
  if (!e || typeof e.id !== 'string') continue;
  if (outlook) {
    if (e.isCancelled || e.showAs === 'free') continue;
    if (Array.isArray(e.singleValueExtendedProperties) && e.singleValueExtendedProperties.some((p) => p && p.value)) continue;
    if (!e.start || !e.end || typeof e.start.dateTime !== 'string' || typeof e.end.dateTime !== 'string') continue;
    // with Prefer: outlook.timezone="UTC" the times come back in UTC, without a zone suffix
    events.push({ id: e.id, start: e.start.dateTime.slice(0, 19) + 'Z', end: e.end.dateTime.slice(0, 19) + 'Z', all_day: !!e.isAllDay });
    continue;
  }
  if (e.status === 'cancelled' || e.transparency === 'transparent') continue;
  if (e.extendedProperties && e.extendedProperties.private && e.extendedProperties.private.zella_appointment_id) continue;
  if (e.start && e.start.dateTime && e.end && e.end.dateTime) events.push({ id: e.id, start: e.start.dateTime, end: e.end.dateTime, all_day: false });
  else if (e.start && e.start.date && e.end && e.end.date) events.push({ id: e.id, start: e.start.date + 'T00:00:00Z', end: e.end.date + 'T00:00:00Z', all_day: true });
}
const complete = [...state.pages, ...events];
if (next) return { json: { next_url: next, access_token: tb.access_token, pages: complete, seen: [...state.seen, next], events: null, error: null } };
// The replacement RPC accepts 500 entries. Merge intervals conservatively when over capacity:
// joining gaps may block extra time, but never drops a busy interval.
let blocks = complete;
if (blocks.length > 500) {
  blocks = blocks.map((e) => ({ ...e, s: Date.parse(e.start), t: Date.parse(e.end) }));
  if (blocks.some((e) => !Number.isFinite(e.s) || !Number.isFinite(e.t) || e.t <= e.s)) return fail(name + '_bad_event_time', false);
  blocks.sort((a, b) => a.s - b.s);
  const merged = [];
  for (const e of blocks) {
    const last = merged[merged.length - 1];
    if (last && e.s <= last.t) last.t = Math.max(last.t, e.t);
    else merged.push({ s: e.s, t: e.t });
  }
  const joins = new Set(merged.slice(1).map((e, i) => ({ i, gap: e.s - merged[i].t }))
    .sort((a, b) => a.gap - b.gap).slice(0, Math.max(0, merged.length - 500)).map((e) => e.i));
  const compact = [];
  for (let i = 0; i < merged.length; i++) {
    if (i && joins.has(i - 1)) compact[compact.length - 1].t = merged[i].t;
    else compact.push({ ...merged[i] });
  }
  blocks = compact.map((e, i) => ({ id: 'zella-busy-union-' + i, start: new Date(e.s).toISOString(), end: new Date(e.t).toISOString(), all_day: false }));
}
return { json: { events: { p_connection_id: plan.connection_id, p_events: blocks }, error: null } };
