#!/usr/bin/env bash
# Exercise the rollback against synthetic functions in an isolated database.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
. "$REPO/tests/lib/isolated_guard.sh"
ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec}
ZPG_PORT=${ZPG_PORT:-55433}
DB=zbrandrollback
zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB"
P=(psql -X -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -v ON_ERROR_STOP=1)
"${P[@]}" -d postgres -c "drop database if exists $DB" -c "create database $DB"
trap '"${P[@]}" -d postgres -c "drop database if exists $DB" >/dev/null' EXIT
rollback() { "${P[@]}" -d "$DB" -f "$REPO/sql/rollback/zella_brand_name_rollback.sql"; }
# First use before the migration, with no helper installed.
rollback
"${P[@]}" -d "$DB" <<'SQL'
create function public.brand_fixture() returns text language sql as $$select 'Zella Voice: welcome to Zella Voice.'::text$$;
create function public.brand_untouched() returns text language sql as $$select 'unchanged'::text$$;
create function public.zella_brand_name_pairs()
returns table(fn text, old_text text, new_text text) language sql as $$
  values ('brand_fixture', 'Zella: ', 'Zella Voice: '),
         ('brand_fixture', 'welcome to Zella.', 'welcome to Zella Voice.')
$$;
SQL
rollback
rollback
"${P[@]}" -d "$DB" <<'SQL'
do $$ begin
  if public.brand_fixture() <> 'Zella: welcome to Zella.' then
    raise exception 'reversal failed';
  end if;
  if public.brand_untouched() <> 'unchanged' then
    raise exception 'unrelated function changed';
  end if;
  if to_regprocedure('public.zella_brand_name_pairs()') is not null then
    raise exception 'helper was not dropped';
  end if;
end $$;
SQL
echo 'PASS absent helper, multiple reversals, cleanup, repeat rollback and unrelated function'
