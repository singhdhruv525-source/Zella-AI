const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync(__dirname + '/../../web/src/BusinessSettings.jsx', 'utf8');
// Exercise the registry's actual React key and the component's loader. A changed key causes React to
// discard the old form (whose initial state comes from the previous schedule) before loading the next one.
const key = source.match(/<ReportSchedule key=\{(`[^`]+`\})/)[1].slice(0, -1);
const loader = source.slice(source.indexOf('function ReportSchedule({ w })'), source.indexOf('  if (!canSee)', source.indexOf('function ReportSchedule({ w })')));
const LEAD = vm.runInNewContext(source.match(/const LEAD = [^;]+;/)[0] + '\nLEAD');
const roleIn = (w, roles) => roles.includes(w.role);
test('workspace and visibility transitions replace schedule state and reload only authorized schedules', async () => {
  const requests = [];
  let previousKey, state;
  for (const w of [
    { id: 'workspace-a', role: 'owner' }, { id: 'workspace-b', role: 'manager' },
    { id: 'workspace-b', role: 'staff' }, { id: 'workspace-b', role: 'owner' },
    { id: 'workspace-a', role: 'viewer' }, { id: 'workspace-a', role: 'manager' }, { id: 'workspace-c', role: 'admin' },
  ]) {
    const context = { w, LEAD, roleIn, Promise,
      rpc: async (name, args) => { requests.push(args.p_business_id); return [{ business_id: args.p_business_id }]; },
      useAsync: (load) => { state = { load }; },
    };
    const nextKey = vm.runInNewContext(key, context);
    assert.notEqual(nextKey, previousKey);
    previousKey = nextKey;
    vm.runInNewContext(loader + '\n}; ReportSchedule({ w });', context);
    const rows = await state.load();
    assert.equal(rows.length, ['owner', 'admin', 'manager'].includes(w.role) ? 1 : 0);
    if (rows.length) assert.equal(rows[0].business_id, w.id);
  }
  assert.deepEqual(requests, ['workspace-a', 'workspace-b', 'workspace-b', 'workspace-a', 'workspace-c']);
  assert.match(source, /if \(!canSee\) return .*Only owners, admins and managers can see the daily report/);
});
