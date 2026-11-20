#!/usr/bin/env bash
# Reference fixture checks (UI-35), local isolated server only:
#  1. the guard (no email address, phone number, link, business id; live switches off; exporter refuses the rest)
#  2. the loader refuses a non isolated target
#  3. a fresh copy of the production schema (TEMPLATE, default zprod3) loads the fixture, twice, with the expected rows
#   tests/fixtures/run.sh            (env ZPG_HOST ZPG_PORT TEMPLATE)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=zfix_reference; TEMPLATE=${TEMPLATE:-zprod3}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
# TEMPLATE goes into "create database ... template $TEMPLATE": only a plain test database name, never SQL or an option
[[ "$TEMPLATE" =~ ^z[a-z0-9_]{1,40}$ ]] || { echo "REFUSED: '$TEMPLATE' is not a test template name (z..., lower case)" >&2; exit 1; }
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }

node "$HERE/reference_guard.mjs" || fails=$((fails + 1))

ZPG_HOST=db.example.invalid "$HERE/load_reference.sh" "$DB" > /dev/null 2>&1 && bad "loader accepted a network host" || ok "loader refuses a network host"
ZPG_HOST=/tmp "$HERE/load_reference.sh" "$DB" > /dev/null 2>&1 && bad "loader accepted another socket directory" || ok "loader refuses a server that is not the isolated cluster"
"$HERE/load_reference.sh" postgres > /dev/null 2>&1 && bad "loader accepted a non test database" || ok "loader refuses a database that is not a test database"

"${P[@]}" -d postgres -c "drop database if exists $DB" -c "create database $DB template $TEMPLATE" > /dev/null || exit 1
want="industries=28 modules=280 platform_templates=56 configurations=28 automation_defaults=191 live_switches_on=0"
snap() { "${P[@]}" -d $DB -c "select md5(string_agg(t, '|' order by t)) from (
  select i.slug || i.name || coalesce(i.description, '') || i.is_active t from industries i
  union all select i.slug || m.slug || m.name || coalesce(m.description, '') || m.is_active from industry_modules m join industries i on i.id = m.industry_id
  union all select i.slug || c.terminology::text || c.statuses::text || c.features::text from industry_configurations c join industries i on i.id = c.industry_id
  union all select i.slug || d.trigger_type || d.enabled || d.config::text from industry_automation_defaults d join industries i on i.id = d.industry_id
  union all select coalesce(i.slug, '') || t.key || t.channel || t.purpose || t.locale || coalesce(t.subject, '') || t.body || t.version || t.status from message_templates t left join industries i on i.id = t.industry_id where t.business_id is null
  union all select key || value::text from platform_settings) x"; }
got=$("$HERE/load_reference.sh" "$DB") && [ "$got" = "$want" ] && ok "loads into a copy of $TEMPLATE: $got" || bad "first load: $got"
first=$(snap)
got=$("$HERE/load_reference.sh" "$DB") && [ "$got" = "$want" ] && [ "$(snap)" = "$first" ] && ok "loads again with no change (idempotent)" || bad "second load: $got"
n=$("${P[@]}" -d $DB -c "select count(*) from message_templates where business_id is not null")
[ "$n" = 0 ] && ok "no business templates" || bad "business templates: $n"
"${P[@]}" -d postgres -c "drop database if exists $DB" > /dev/null
echo; [ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
