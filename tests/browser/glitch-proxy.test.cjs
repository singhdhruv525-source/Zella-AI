const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
for (const file of ['glitch-sweep.cjs', 'glitch-interact.cjs']) {
  const source = fs.readFileSync(`${__dirname}/${file}`, 'utf8');
  const routing = source.slice(source.indexOf('await ctx.route('), source.indexOf('const page = await ctx.newPage();'));
  test(`${file}: combined routing permits only local and font network requests`, async () => {
    for (const protocol of ['http', 'https']) {
      const cases = [
        ['zlocal.supabase.co/auth', 'proxy'], ['zlocal.supabase.co:443/auth', 'proxy'],
        ['zlocal.supabase.co:54321/auth', 'proxy'], ['zlocal.supabase.co//external.test/auth', 'proxy'],
        ['user@zlocal.supabase.co/auth', 'abort'], ['zlocal.supabase.co@external.test/auth', 'abort'],
        ['user@localhost/auth', 'abort'], ['external.test/auth', 'empty'],
        ['zlocal.supabase.co.external.test/auth', 'empty'], ['localhost:5199/auth', 'network'],
        ['127.0.0.1/auth', 'network'], ['[::1]:5199/auth', 'network'],
        ['fonts.googleapis.com/css', 'network'], ['fonts.gstatic.com/font', 'network'],
        ['fonts.gstatic.com:54321/font', 'empty'],
      ];
      for (const [address, expected] of cases) {
        for (const location of [null, '/safe', '//localhost:54321/safe', 'http://127.0.0.1/safe',
          'https://[::1]:443/safe', '//external.test/path', 'javascript:alert(1)', 'http://[invalid',
          'http://user@localhost/safe']) {
          const handlers = [];
          let outcome, fetches = 0;
          await vm.runInNewContext(`(async () => { ${routing} })()`, {
            ctx: { route: async (pattern, handler) => handlers.push({ pattern, handler }) },
            BACKEND: 'http://localhost:54321', URL, Buffer,
            fetch: async (url, options) => {
              fetches++;
              assert.equal(new URL(url).origin, 'http://localhost:54321');
              assert.equal(options.redirect, 'manual');
              return { status: location ? 302 : 200, headers: new Headers(location ? { location } : {}),
                arrayBuffer: async () => new ArrayBuffer(0) };
            },
          });
          const url = new URL(`${protocol}://${address}`);
          const match = handlers.reverse().find(({ pattern }) => pattern(url));
          assert.ok(match);
          await match.handler({
            request: () => ({ url: () => url.href, method: () => 'GET', headers: () => ({}) }),
            abort: async () => { outcome = 'abort'; },
            continue: async () => { outcome = 'network'; },
            fulfill: async () => { outcome = fetches ? 'proxy' : 'empty'; },
          });
          const safe = !location || ['/safe', '//localhost:54321/safe', 'http://127.0.0.1/safe', 'https://[::1]:443/safe'].includes(location);
          assert.equal(outcome, expected === 'proxy' && !safe ? 'abort' : expected, url.href + ' ' + location);
          assert.equal(fetches, expected === 'proxy' ? 1 : 0);
        }
      }
    }
  });
}
