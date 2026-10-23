// Shared by build.mjs and test.mjs, so the tests run exactly the code that ships.
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const eventTypes = JSON.parse(readFileSync(join(here, 'events.json'), 'utf8'));

export function loadCode(file, vars = {}) {
  let text = readFileSync(join(here, file), 'utf8').replace('__EVENT_TYPES__', JSON.stringify(eventTypes));
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
