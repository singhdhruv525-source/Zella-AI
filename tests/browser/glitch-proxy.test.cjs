const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
for (const file of ['glitch-sweep.cjs', 'glitch-interact.cjs']) {
  const source = fs.readFileSync(`${__dirname}/${file}`, 'utf8');
  const start = source.indexOf('await ctx.route(');
  const end = source.indexOf('//', source.indexOf('});', start));
  test(`${file}: HTTP and HTTPS proxy responses and redirect isolation`, async () => {
    for (const protocol of ['http', 'https']) for (const location of [null, '/safe', '//localhost:54321/safe', 'http://127.0.0.1/safe', '//external.test/path', 'https://external.test', 'javascript:alert(1)', 'http://[invalid']) {
      let handler, pattern, aborted = false, fulfilled = false;
      await vm.runInNewContext(`(async () => { ${source.slice(start, end)} })()`, {
        ctx: { route: async (p, h) => { pattern = p; handler = h; } }, BACKEND: 'http://localhost:54321', URL, Buffer,
        fetch: async (url, options) => {
          assert.equal(options.redirect, 'manual');
          assert.equal(url, 'http://localhost:54321/auth');
          return { status: location ? 302 : 200, url, headers: new Headers(location ? { location } : {}), arrayBuffer: async () => new ArrayBuffer(0) };
        },
      });
      assert.ok(pattern.test(`${protocol}://zlocal.supabase.co/auth`));
      await handler({ request: () => ({ url: () => `${protocol}://zlocal.supabase.co/auth`, method: () => 'GET', headers: () => ({}) }), abort: async () => { aborted = true; }, fulfill: async () => { fulfilled = true; } });
      const safe = !location || ['/safe', '//localhost:54321/safe', 'http://127.0.0.1/safe'].includes(location);
      assert.equal(fulfilled, safe, location);
      assert.equal(aborted, !safe, location);
    }
  });
}
