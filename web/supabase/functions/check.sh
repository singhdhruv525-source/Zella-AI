#!/usr/bin/env bash
# Type-checks every edge function the way Supabase bundles them: Deno's own package cache, not web/node_modules
# (each function's deno.json sets "nodeModulesDir": "none"; without it Deno picks up web/package.json and cannot find
# the npm typings that @supabase/functions-js/edge-runtime.d.ts refers to). Usage: web/supabase/functions/check.sh
set -uo pipefail
cd "$(dirname "$0")"
DENO=${DENO:-deno}; fail=0
for f in */; do
  f=${f%/}; [ "$f" = _shared ] && continue
  if (cd "$f" && "$DENO" check --no-lock index.ts > /dev/null 2> "/tmp/zella-check-$f.log"); then echo "ok   $f"; else echo "FAIL $f"; grep -m5 -E "error|TS[0-9]" "/tmp/zella-check-$f.log"; fail=1; fi
done
exit $fail
