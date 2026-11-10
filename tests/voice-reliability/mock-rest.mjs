// Stand-in for PostgREST, for tests only: POST /rest/v1/rpc/<fn> with JSON args -> select public.<fn>(named args).
// Uses the staging database (ZPSQL + ZDB). Never point this at production.
import { createServer } from 'node:http';
import { execFile } from 'node:child_process';
import { readFileSync } from 'node:fs';
const cmd = process.env.ZPSQL + ' -d ' + (process.env.ZDB || 'zvoice');
const q = (v) => v === null || v === undefined ? 'null' : typeof v === 'object' ? "'" + JSON.stringify(v).replace(/'/g, "''") + "'::jsonb" : typeof v === 'number' ? String(v) : "'" + String(v).replace(/'/g, "''") + "'";
createServer((req, res) => {
  let b = ''; req.on('data', (c) => (b += c)); req.on('end', () => {
    const fn = (req.url.match(/\/rest\/v1\/rpc\/([a-z_]+)/) || [])[1];
    // tests can make one function slow, unreachable or return junk: MOCK_CONTROL holds "<mode>:<fn>" or "<mode>:<fn>:<p_tool>",
    // mode = slow | down | junk
    let ctl = ''; try { ctl = process.env.MOCK_CONTROL ? readFileSync(process.env.MOCK_CONTROL, 'utf8').trim() : ''; } catch { ctl = ''; }
    const args = JSON.parse(b || '{}');
    const [mode, cfn, ctool] = ctl.split(':');
    if (mode && cfn === fn && (!ctool || ctool === args.p_tool)) {
      if (mode === 'down') { res.writeHead(503); res.end('{}'); return; }
      if (mode === 'junk') { res.writeHead(200, { 'content-type': 'application/json' }); res.end('[1,"two",{"say":5}]'); return; }
      if (mode === 'slow') { setTimeout(() => { try { res.writeHead(200); res.end('null'); } catch { /* client gone */ } }, 10000); return; }
    }
    const sql = `select to_jsonb(public.${fn}(${Object.entries(args).map(([k, v]) => `${k} => ${q(v)}`).join(', ')}))::text`;
    // asynchronous: concurrent requests really run at the same time in the database, as with PostgREST
    const child = execFile('su', ['nobody', '-s', '/bin/bash', '-c', cmd], (err, stdout, stderr) => {
      if (err) { res.writeHead(400, { 'content-type': 'application/json' }); res.end(JSON.stringify({ code: 'P0001', message: String(stderr || err).split('\n')[0] })); return; }
      res.writeHead(200, { 'content-type': 'application/json' }); res.end(String(stdout).trim() || 'null');
    });
    child.stdin.end(sql);
  });
}).listen(54400, () => console.log('mock rest on 54400'));
