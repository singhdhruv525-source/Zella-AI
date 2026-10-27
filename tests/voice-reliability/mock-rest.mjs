// Stand-in for PostgREST, for tests only: POST /rest/v1/rpc/<fn> with JSON args -> select public.<fn>(named args).
// Uses the staging database (ZPSQL + ZDB). Never point this at production.
import { createServer } from 'node:http';
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
const cmd = process.env.ZPSQL + ' -d ' + (process.env.ZDB || 'zvoice');
const q = (v) => v === null || v === undefined ? 'null' : typeof v === 'object' ? "'" + JSON.stringify(v).replace(/'/g, "''") + "'::jsonb" : typeof v === 'number' ? String(v) : "'" + String(v).replace(/'/g, "''") + "'";
createServer((req, res) => {
  let b = ''; req.on('data', (c) => (b += c)); req.on('end', () => {
    const fn = (req.url.match(/\/rest\/v1\/rpc\/([a-z_]+)/) || [])[1];
    // tests can make one function slow or unreachable: MOCK_CONTROL file holds "slow:<fn>" or "down:<fn>"
    let ctl = ''; try { ctl = process.env.MOCK_CONTROL ? readFileSync(process.env.MOCK_CONTROL, 'utf8').trim() : ''; } catch { ctl = ''; }
    if (ctl === 'down:' + fn) { res.writeHead(503); res.end('{}'); return; }
    if (ctl === 'slow:' + fn) { setTimeout(() => { try { res.writeHead(200); res.end('null'); } catch { /* client gone */ } }, 10000); return; }
    const args = JSON.parse(b || '{}');
    const sql = `select to_jsonb(public.${fn}(${Object.entries(args).map(([k, v]) => `${k} => ${q(v)}`).join(', ')}))::text`;
    try {
      const out = execFileSync('su', ['nobody', '-s', '/bin/bash', '-c', cmd], { input: sql, stdio: ['pipe', 'pipe', 'pipe'] }).toString().trim();
      res.writeHead(200, { 'content-type': 'application/json' }); res.end(out || 'null');
    } catch (e) {
      res.writeHead(400, { 'content-type': 'application/json' }); res.end(JSON.stringify({ code: 'P0001', message: String(e.stderr || e).split('\n')[0] }));
    }
  });
}).listen(54400, () => console.log('mock rest on 54400'));
