#!/usr/bin/env bash
# Loads tests/fixtures/reference_config.sql (production CONFIGURATION, no customer data; UI-35) into a database on the
# ISOLATED test server only. Anything else is refused by tests/lib/isolated_guard.sh before any SQL runs: a network
# host, a hosted (Supabase) database, a server whose data directory is not the throwaway test cluster, or a database
# name that is not a test name (z..., lower case). Idempotent: loading twice leaves the same rows.
#   tests/fixtures/load_reference.sh <db>        (env ZPG_HOST, ZPG_PORT; defaults are the isolated server)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
DB="${1:-}"; [ -n "$DB" ] || { echo "usage: $0 <test database>" >&2; exit 2; }
. "$REPO/tests/lib/isolated_guard.sh"   # also clears PGHOST, PGHOSTADDR, PGSERVICE, ... so nothing can redirect psql
H=${ZPG_HOST:-/var/lib/postgresql/zella-sec}; P=${ZPG_PORT:-55433}
zella_require_isolated "$H" "$P" "$DB" || exit 1
PSQL=(psql -h "$H" -p "$P" -U postgres -d "$DB" -qtAX -v ON_ERROR_STOP=1)
"${PSQL[@]}" -f "$HERE/reference_config.sql" > /dev/null || { echo "load_reference: loading failed" >&2; exit 1; }
"${PSQL[@]}" -c "select 'industries=' || (select count(*) from public.industries)
  || ' modules=' || (select count(*) from public.industry_modules)
  || ' platform_templates=' || (select count(*) from public.message_templates where business_id is null)
  || ' configurations=' || (select count(*) from public.industry_configurations)
  || ' automation_defaults=' || (select count(*) from public.industry_automation_defaults)
  || ' live_switches_on=' || (select count(*) from public.platform_settings where (key like '%\_live' or key = 'n8n_dispatch_enabled') and value <> 'false'::jsonb)"
