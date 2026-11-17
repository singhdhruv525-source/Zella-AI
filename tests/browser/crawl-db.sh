#!/usr/bin/env bash
# Builds the database the page crawls and journeys use, on the ISOLATED test server only: a fresh copy of the
# production schema, then the reference configuration (tests/fixtures/reference_config.sql: industries, modules,
# configurations, automation defaults, platform templates and settings copied read only from production; no customer
# data; every live switch off). Test people and businesses are added afterwards (see README.md).
#   tests/browser/crawl-db.sh [db]          (default zella_ui; env ZPG_HOST ZPG_PORT TEMPLATE, default zprod3)
# TEMPLATE is any isolated copy of the production schema, for example zfull from tests/lib/build_full.sh.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"; DB="${1:-zella_ui}"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
T=${TEMPLATE:-zprod3}
[[ "$T" =~ ^z[a-z0-9_]{1,40}$ ]] || { echo "crawl-db: '$T' is not a test template name" >&2; exit 1; }
# never drop the template itself or a shared schema copy
case "$DB" in "$T"|zprod|zprod2|zprod3|zfull|zbase) echo "crawl-db: '$DB' is a template database and will not be dropped" >&2; exit 1;; esac
"${P[@]}" -d postgres -c "select pg_terminate_backend(pid) from pg_stat_activity where datname = '$DB' and pid <> pg_backend_pid()" > /dev/null
"${P[@]}" -d postgres -c "drop database if exists $DB" -c "create database $DB template $T" > /dev/null || { echo "crawl-db: copy of $T failed" >&2; exit 1; }
"$REPO/tests/fixtures/load_reference.sh" "$DB" || exit 1
echo "crawl database $DB ready"
