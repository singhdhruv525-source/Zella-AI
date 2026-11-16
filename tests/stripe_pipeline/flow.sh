#!/usr/bin/env bash
# The whole Stripe path, locally: signed events from the fake Stripe (tests/stripe_fake) -> billing-webhook ->
# the isolated database (through tests/browser/local-backend.mjs) -> billing-worker fetching from the fake -> applied.
# Never reaches Stripe or production. Usage: tests/stripe_pipeline/flow.sh [test file] [extra migrations...]
HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/lib.sh"
TEST=${1:-$HERE/flow_test.ts}; shift || true
zf_build zlf_t_flow zella_stripe_pipeline "$@"
PORT=${ZF_BACKEND_PORT:-54336}
ZDB=$DB PORT=$PORT node "$ZF_REPO/tests/browser/local-backend.mjs" > /tmp/zlf_backend.log 2>&1 & BK=$!
trap 'kill $BK 2>/dev/null' EXIT
for i in $(seq 1 40); do curl -s -o /dev/null "http://127.0.0.1:$PORT/rest/v1/" && break; sleep 0.25; done
ZF_DB=$DB ZF_BACKEND="http://127.0.0.1:$PORT" deno test --no-lock --allow-net=127.0.0.1 --allow-env --allow-run=psql --allow-read "$TEST"
