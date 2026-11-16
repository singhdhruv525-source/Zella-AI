-- Rollback of sql/zella_recording_policy.sql: removes the per business recording policy, its guards and functions, and
-- the two settings. Safe to run twice. Refuses (ROLLBACK_DRIFT) if any function differs from that file's version, if
-- legal approval is recorded, if the disclosure text is set, or if any business's recording is on (each would be lost).
-- The audit trail stays in audit_logs.
begin;

do $$
declare
  f record;
  busy boolean := false;
    mine constant jsonb := '{
    "public.zella_recording_setting_guard()": "6d3ebb3ae696080e27205a1f6d326e77",
    "public.zella_recording_policy_guard()": "8fd784b180e1bbffa4095521ba2b4bb5",
    "public.zella_recording_effective(uuid)": "104511e50db0dc4c549ce555d2578b74",
    "public.zella_recording_policies(uuid)": "24008889cb73a40039aff433a86b53b8",
    "public.zella_recording_policy_set(uuid,uuid,boolean,text)": "3cb4ba4d22b5fd87b6f02bc49df41266",
    "public.zella_recording_legal_set(uuid,boolean,text,text)": "25ddee21113eae69b5ae3b12c8598b0a"
  }';
begin
  for f in select key as sig, value #>> '{}' as want from jsonb_each(mine) loop
    if to_regprocedure(f.sig) is not null and md5(pg_get_functiondef(f.sig::regprocedure)) <> f.want then
      raise exception 'ROLLBACK_DRIFT: % has changed since zella_recording_policy.sql', f.sig;
    end if;
  end loop;
  if exists (select 1 from public.platform_settings where (key = 'recording_legal_approved' and value <> 'false'::jsonb)
                                                       or (key = 'recording_disclosure_text' and value <> '""'::jsonb)) then
    raise exception 'ROLLBACK_DRIFT: legal approval or the disclosure text is recorded; a Zella Voice owner clears them first';
  end if;
  if to_regclass('public.business_recording_policies') is not null then
    execute 'select exists (select 1 from public.business_recording_policies where recording_on)' into busy;
  end if;
  if busy then raise exception 'ROLLBACK_DRIFT: a business has recording on; switch it off first'; end if;
end $$;

drop trigger if exists zella_recording_setting_guard on public.platform_settings;
drop function if exists public.zella_recording_legal_set(uuid, boolean, text, text);
drop function if exists public.zella_recording_policy_set(uuid, uuid, boolean, text);
drop function if exists public.zella_recording_policies(uuid);
drop function if exists public.zella_recording_effective(uuid);
drop table if exists public.business_recording_policies;
drop function if exists public.zella_recording_policy_guard();
drop function if exists public.zella_recording_setting_guard();
delete from public.platform_settings where key in ('recording_legal_approved', 'recording_disclosure_text');

commit;
