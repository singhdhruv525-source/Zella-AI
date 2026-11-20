-- Zella Voice: website addresses on wildcard DNS services are refused when they are added (security audit 18 Nov 2026,
-- 5.4, M9). zella_website_url_ok (used when an owner, admin or manager adds a website source, and again when a page is
-- queued) refused internal names by their text but not names on services such as nip.io or sslip.io, which answer any
-- name with any address (127.0.0.1.nip.io is 127.0.0.1). The real protection is in the website-fetch edge function,
-- which resolves the name and refuses private and metadata addresses before it connects; this is the early check.
-- The function is archived first and must match production (18 Nov 2026), otherwise VERSION_MISMATCH.
-- Rollback: sql/rollback/zella_website_fetch_guard_rollback.sql
begin;

do $$
declare s constant text := 'public.zella_website_url_ok(text)'; d text;
begin
  if to_regprocedure(s) is null or to_regclass('public.zella_function_archive') is null then
    raise exception 'VERSION_MISMATCH: something this file needs is missing';
  end if;
  d := pg_get_functiondef(s::regprocedure);
  if md5(d) = 'a3df67d26716645b5f52551965f536e2' then          -- production's version: archive it for the rollback
    insert into public.zella_function_archive (migration, signature, definition, definition_md5)
    values ('zella_website_fetch_guard', s, d, md5(d)) on conflict (migration, signature) do nothing;
  elsif md5(d) <> '23c362d28709b0567a7427d2f253009e' then                               -- nor exactly this file's version (already applied)
    raise exception 'VERSION_MISMATCH: % is not a version this file was written for', s;
  end if;
end $$;

CREATE OR REPLACE FUNCTION public.zella_website_url_ok(p_url text)
 RETURNS boolean
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
declare u text := lower(coalesce(p_url, '')); v_host text; v_port text;
begin
  if length(u) < 10 or length(u) > 2000 or u ~ '\s' or u ~ '[<>"''\\]' then return false; end if;
  if u !~ '^https?://[a-z0-9.-]+(:[0-9]{1,5})?(/|\?|$)' then return false; end if;
  v_host := substring(u from '^https?://([a-z0-9.-]+)');
  v_port := substring(u from '^https?://[a-z0-9.-]+:([0-9]{1,5})');
  if v_port is not null and v_port not in ('80', '443') then return false; end if;
  if v_host !~ '\.' or v_host ~ '^\.|\.$|\.\.' then return false; end if;
  if v_host ~ '^[0-9.]+$' then return false; end if;
  if v_host ~ '(^|\.)(localhost|local|internal|lan|home|corp|intranet|localdomain|test|invalid|example)$' then return false; end if;
  -- wildcard DNS services that answer any name with any address (security audit 18 Nov 2026, M9)
  if v_host ~ '(^|\.)(nip\.io|sslip\.io|xip\.io|nip\.direct|localtest\.me|lvh\.me|vcap\.me|lacolhost\.com|traefik\.me|localhost\.direct)$' then return false; end if;
  if length(v_host) > 253 then return false; end if;
  return true;
end $function$;

commit;
