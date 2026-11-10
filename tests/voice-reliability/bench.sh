#!/bin/bash
# Latency measurement of the synchronous voice path in staging (run after run_all.sh, which builds zvoice).
set -u
cd "$(dirname "$0")"; REPO=$(cd ../.. && pwd)
export ZPSQL=${ZPSQL:-"psql -q -At -v ON_ERROR_STOP=1 -h /var/tmp/zella-pg -p 54329 -U postgres"} ZDB=${ZDB:-zvoice}
DENO=${DENO:-deno}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/zella-bench.XXXX"); chmod 755 "$WORK"
export TEST_HMAC_SECRET="test-only-$(date +%s%N)-hmac" MOCK_CONTROL="$WORK/mock.ctl"
echo "delete from vault.decrypted_secrets where name like 'zella_vapi_%'; delete from platform_settings where key = 'vapi_auth_mode'; insert into vault.decrypted_secrets values ('zella_vapi_hmac_secret', '$TEST_HMAC_SECRET')" | su nobody -s /bin/bash -c "$ZPSQL -d $ZDB" > /dev/null
: > "$MOCK_CONTROL"; chmod 666 "$MOCK_CONTROL"
node mock-rest.mjs > "$WORK/mock.log" 2>&1 & MOCK=$!
( cd "$REPO/web/supabase/functions/voice-rules" && exec env SUPABASE_URL=http://127.0.0.1:54400 ZELLA_SERVER_SECRET_KEY=test-key NO_PROXY=127.0.0.1 no_proxy=127.0.0.1 \
  "$DENO" run --allow-net --allow-env --allow-read --allow-sys index.ts > "$WORK/fn.log" 2>&1 ) & FN=$!
for i in $(seq 1 30); do curl -s -o /dev/null --max-time 1 http://127.0.0.1:8000 && break; sleep 1; done
NO_PROXY=127.0.0.1 no_proxy=127.0.0.1 node bench.mjs
kill $FN $MOCK 2>/dev/null; wait $FN $MOCK 2>/dev/null; rm -rf "$WORK"
