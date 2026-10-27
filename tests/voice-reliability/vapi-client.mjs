// Test client for voice-rules: signs every request the way Vapi's HMAC credential does (sha256 over
// "{timestamp}.{body}", hex, x-signature / x-timestamp) with the TEST secret in TEST_HMAC_SECRET. Staging only.
import { createHmac } from 'node:crypto';
import { writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
export const SECRET = process.env.TEST_HMAC_SECRET;
export const URL_ = 'http://127.0.0.1:8000';
export const sql = (q) => execFileSync('su', ['nobody', '-s', '/bin/bash', '-c', process.env.ZPSQL + ' -d ' + (process.env.ZDB || 'zvoice')], { input: q }).toString().trim();
export const sign = (raw, ts, secret = SECRET) => createHmac('sha256', secret).update(ts + '.' + raw).digest('hex');
export const now = () => String(Math.floor(Date.now() / 1000));
export const send = (raw, headers = {}) => fetch(URL_, { method: 'POST', headers: { 'content-type': 'application/json', ...headers }, body: raw });
export const P = (body, o = {}) => { const raw = typeof body === 'string' ? body : JSON.stringify(body); const ts = o.ts ?? now();
  return send(raw, { 'x-timestamp': ts, 'x-signature': sign(raw, ts, o.secret), ...(o.headers || {}) }); };
export const control = (v) => writeFileSync(process.env.MOCK_CONTROL, v);
export const callA = (id, extra = {}) => ({ id, type: 'inboundPhoneCall', customer: { number: '+15551230001' }, phoneNumber: { number: '+15550001000' }, phoneNumberId: 'pn-A', ...extra });
export const counter = () => { let pass = 0, fail = 0; return { ok: (c, m) => { c ? pass++ : fail++; console.log((c ? 'PASS ' : 'FAIL ') + m); }, done: () => { console.log(`${pass} passed, ${fail} failed`); return fail; } }; };
