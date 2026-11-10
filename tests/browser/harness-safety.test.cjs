const { test } = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { EventEmitter } = require('node:events');
const vm = require('node:vm');
const path = require('node:path');
const read = (name) => readFileSync(path.join(__dirname, name), 'utf8');

test('isolated guard rejects unsafe targets and strips libpq redirects', () => {
  let result = '/var/lib/postgresql/zella-sec/data', calls = [];
  const context = { module: { exports: {} }, process: { env: { PGHOSTADDR: 'evil', PGSERVICE: 'evil', PGSERVICEFILE: '/evil', PGDATABASE: 'prod', PATH: '/bin' } },
    require: () => ({ execFileSync: (...args) => { calls.push(args); return Buffer.from(result); } }) };
  vm.runInNewContext(read('isolated-db.cjs'), context);
  const { PSQL_ENV, requireIsolated } = context.module.exports;
  assert.deepEqual(Object.keys(PSQL_ENV), ['PATH']);
  for (const [host, db] of [['remote', 'ztest'], ['/socket,remote', 'ztest'], ['/socket,/other', 'ztest'], ['/socket,', 'ztest'], ['/socket', 'production'], ['/socket', 'ztest?host=remote']]) {
    assert.throws(() => requireIsolated(host, '55433', db), /REFUSED/);
  }
  assert.equal(calls.length, 0);
  for (result of ['', '/production/data']) assert.throws(() => requireIsolated('/socket', '55433', 'ztest'), /REFUSED/);
  result = '/var/lib/postgresql/zella-sec/data';
  requireIsolated('/socket', '55433', 'ztest');
  assert.equal(calls.at(-1)[2].env, PSQL_ENV);
});

test('local backend guards before binding and limits CORS to trusted origins', async () => {
  let guarded = 0, handler;
  const binds = [];
  const source = read('local-backend.mjs').replace(/^import .*;\n/gm, '').replace(/export /g, '');
  vm.runInNewContext(source, {
    process: { env: {} }, Buffer, URL, console,
    http: { createServer: (fn) => { handler = fn; return { on() { return this; }, listeners: () => [fn], listen: (...args) => { assert.equal(guarded, 1); binds.push(args); } }; } },
    requireIsolated: () => guarded++, PSQL_ENV: {}, crypto: require('node:crypto'),
  });
  assert.deepEqual(binds.map((args) => args[1]).sort(), ['127.0.0.1', '::1']);
  for (const origin of ['http://localhost:5199', 'http://127.0.0.1:5199', 'http://[::1]:5199', 'https://evil.test', 'null', undefined]) {
    let headers;
    await handler({ method: 'OPTIONS', headers: { origin } }, { writeHead: (_, h) => { headers = h; }, end() {} });
    assert.equal(headers['access-control-allow-origin'], origin?.includes(':5199') ? origin : undefined);
    if (!origin?.includes(':5199')) assert.equal(headers['access-control-allow-credentials'], undefined);
  }
});

test('IPv6 bind failures leave IPv4 available and report unexpected errors', () => {
  const source = read('local-backend.mjs').replace(/^import .*;\n/gm, '').replace(/export /g, '');
  for (const code of ['EADDRNOTAVAIL', 'EAFNOSUPPORT', 'EADDRINUSE', 'EACCES']) {
    const binds = [], errors = [];
    let guarded = false;
    vm.runInNewContext(source, {
      process: { env: {} }, Buffer, URL,
      console: { error: (...args) => errors.push(args) },
      http: { createServer: (fn) => {
        const listener = new EventEmitter();
        listener.listeners = () => [fn];
        listener.listen = (_, host) => {
          assert.equal(guarded, true);
          binds.push(host);
          if (host === '::1') listener.emit('error', Object.assign(new Error(code), { code }));
        };
        return listener;
      } },
      requireIsolated: () => { guarded = true; }, PSQL_ENV: {}, crypto: require('node:crypto'),
    });
    assert.deepEqual(binds, ['::1', '127.0.0.1']);
    assert.equal(errors.length, ['EADDRNOTAVAIL', 'EAFNOSUPPORT'].includes(code) ? 0 : 1);
    if (errors.length) assert.equal(errors[0][1].code, code);
  }
});

test('mock REST rejects malformed bodies and identifiers before executing SQL', () => {
  let handler, sql, calls = 0;
  vm.runInNewContext(read('../voice-reliability/mock-rest.mjs').replace(/^import .*;\n/gm, ''), {
    process: { env: { ZPSQL: 'psql' } }, console,
    createServer: (fn) => { handler = fn; return { listen: (_, host) => assert.equal(host, '127.0.0.1') }; },
    execFile: () => { calls++; return { stdin: { end: (s) => { sql = s; } } }; },
  });
  for (const body of ['{', 'null', '[]', '{"x); drop table users;--":1}', '{"bad\\"name":1}']) {
    const req = new EventEmitter(); req.url = '/rest/v1/rpc/test_fn'; let status;
    handler(req, { writeHead: (s) => { status = s; }, end() {} });
    req.emit('data', body); req.emit('end');
    assert.equal(status, 400);
  }
  assert.equal(calls, 0);
  const req = new EventEmitter(); req.url = '/rest/v1/rpc/test_fn';
  handler(req, {}); req.emit('data', JSON.stringify({ p_name: "O'Brien", select: null })); req.emit('end');
  assert.equal(calls, 1);
  assert.match(sql, /"p_name" => 'O''Brien'/);
  assert.match(sql, /"select" => null/);
});

test('retry requires both a dismissed notice and an allowed saved sidebar', () => {
  const expression = read('appearance-save.cjs').split('check("Try again from the notice saves and the notice goes away", ')[1].split('\n')[0].replace(/\);$/, '');
  const check = new Function('notice', 'account', `return (async () => (${expression}))()`);
  return Promise.all([0, 1].flatMap((count) => ['compact', 'full', 'other'].map(async (sidebar) => {
    assert.equal(await check({ count: async () => count }, { meta: { crm: { sidebar } } }), count === 0 && sidebar !== 'other');
  })));
});

test('batch1 reports applies twice only when both migration runs succeed', () => {
  const { spawnSync } = require('node:child_process');
  const source = read('../security/batch1/run.sh');
  const loop = source.slice(source.indexOf('fails=0'), source.indexOf('out=$($P -d "$DB" -f "$HERE/test.sql"'));
  for (const failedRun of [0, 1, 2]) {
    const result = spawnSync('bash', ['-c', `mock() { [ "$i" != "${failedRun}" ]; }; P=mock; DB=ztest; REPO=/unused\n${loop}\nprintf 'fails=%s' "$fails"`], { encoding: 'utf8' });
    assert.equal(result.status, 0);
    assert.equal(result.stdout.includes('PASS sql/zella_batch1_security.sql applies twice'), failedRun === 0);
    assert.match(result.stdout, new RegExp(`fails=${failedRun === 0 ? 0 : 1}$`));
    if (failedRun) assert.match(result.stdout, new RegExp(`FAIL batch1 migration run ${failedRun}`));
  }
});
