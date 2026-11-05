#!/usr/bin/env bash
# Local stack with every edge function served by the Supabase edge runtime (Docker image), behind the local Supabase
# stand-in (tests/browser/local-backend.mjs) on the isolated Postgres. Test-only keys and secrets; nothing is sent.
# Usage: tests/runtime/start.sh            (env ZEDGE_VERSION, default v1.78.0; needs dockerd, the image and the zella_ui db)
set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd); OUT=${OUT:-$REPO/tests/runtime/out}; mkdir -p "$OUT"
docker rm -f zedge >/dev/null 2>&1
args=(-e SUPABASE_URL=http://localhost:54321 -e SUPABASE_ANON_KEY=sb_publishable_local_test_only -e SUPABASE_PUBLISHABLE_KEY=sb_publishable_local_test_only
      -e ZELLA_SERVER_SECRET_KEY=sb_secret_local_test_only -e ZELLA_APP_URL=http://localhost:5199
      -e ZELLA_LINK_SECRET=local-link-secret-test-only-0123456789abcdef -e STRIPE_WEBHOOK_SECRET=whsec_local_test_only -e NO_PROXY=localhost,127.0.0.1)
# behind an HTTPS proxy (jsr: and npm: imports are fetched when a function first starts)
[ -n "${HTTPS_PROXY:-}" ] && args+=(-e HTTPS_PROXY="$HTTPS_PROXY" -e HTTP_PROXY="${HTTP_PROXY:-$HTTPS_PROXY}")
[ -f /root/.ccr/ca-bundle.crt ] && args+=(-v /root/.ccr/ca-bundle.crt:/etc/ssl/certs/proxy-ca.crt:ro -e DENO_CERT=/etc/ssl/certs/proxy-ca.crt -e SSL_CERT_FILE=/etc/ssl/certs/proxy-ca.crt)
docker run -d --name zedge --network host -v "$REPO/web/supabase/functions:/home/deno/functions:ro" -v "$REPO/tests/runtime/edge-main:/home/deno/main:ro" "${args[@]}" \
  "public.ecr.aws/supabase/edge-runtime:${ZEDGE_VERSION:-v1.78.0}" start --main-service /home/deno/main --port 54500 > /dev/null
F=$(cd "$REPO/web/supabase/functions" && python3 -c "import json,os; print(json.dumps({d: '54500/' + d for d in sorted(os.listdir('.')) if os.path.isfile(os.path.join(d, 'index.ts'))}))")
pkill -f local-backend.mjs; sleep 0.5
cd "$REPO" && ZFUNCTIONS="$F" nohup node tests/browser/local-backend.mjs > "$OUT/backend.log" 2>&1 &
sleep 6; curl -s -o /dev/null -w "stand-in %{http_code} · " http://localhost:54321/auth/v1/user; curl -s -o /dev/null -w "runtime %{http_code}\n" -X POST http://localhost:54500/google-lead -d '{}'
