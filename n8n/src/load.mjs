// Shared by build.mjs and test.mjs, so the tests run exactly the code that ships.
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const eventTypes = JSON.parse(readFileSync(join(here, 'events.json'), 'utf8'));

// Code shared with the Supabase edge functions: one implementation, inlined into the n8n Code node (exports removed).
const shared = (name) => readFileSync(join(here, '../../web/supabase/functions/_shared', name), 'utf8').replace(/^export /gm, '');

export function loadCode(file, vars = {}) {
  let text = readFileSync(join(here, file), 'utf8').replace('__EVENT_TYPES__', JSON.stringify(eventTypes));
  if (text.includes('__VAPI_CALL_EVENTS__')) text = text.replace('__VAPI_CALL_EVENTS__', () => shared('vapi-call-events.js'));
  for (const [k, v] of Object.entries(vars)) text = text.replaceAll('__' + k + '__', v);
  return text;
}

// Run a Code-node body the way n8n does for "run once for each item".
export function runCode(file, { json = {}, nodes = {}, vars = {} } = {}) {
  const fn = new Function('$json', '$', loadCode(file, vars));
  const lookup = (name) => {
    if (!(name in nodes)) throw new Error('Test did not provide node: ' + name);
    return { item: { json: nodes[name] } };
  };
  return fn(json, lookup);
}

// Same, for Code nodes that read the raw request body (they use await).
const AsyncFn = Object.getPrototypeOf(async function () {}).constructor;
export async function runCodeAsync(file, { json = {}, raw = '', vars = {} } = {}) {
  const fn = new AsyncFn('$json', '$', loadCode(file, vars));
  return fn.call({ helpers: { getBinaryDataBuffer: async () => Buffer.from(raw) } }, json, () => ({ item: { json: {} } }));
}

// Same, for Code nodes that run once for all items ("run once for all items"): they read $input.first() / $input.all().
export function runCodeAll(file, { items = [], nodes = {}, vars = {} } = {}) {
  const fn = new Function('$input', '$', loadCode(file, vars));
  const $input = { first: () => items[0], all: () => items, item: items[0] };
  const lookup = (name) => {
    if (!(name in nodes)) throw new Error('Test did not provide node: ' + name);
    return { item: { json: nodes[name] }, all: () => [].concat(nodes[name]).map((json) => ({ json })) };
  };
  return fn($input, lookup);
}
