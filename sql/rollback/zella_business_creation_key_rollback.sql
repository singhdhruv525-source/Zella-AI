-- Undoes sql/zella_business_creation_key.sql exactly: drops zella_create_business_draft(jsonb, uuid),
-- zella_business_duplicates and businesses.creation_key (with its index). The one argument zella_create_business_draft
-- was never changed, so it stays as it is. Each function must be exactly that file's version, otherwise ROLLBACK_DRIFT
-- and nothing changes. Deploy the earlier owner-provision-business first: the new one calls the two argument function.
-- Safe to run twice.
begin;
do $$
declare f record;
begin
  for f in select * from (values
      ('public.zella_create_business_draft(jsonb,uuid)', '9a8eecb43decf5cf400010631027c208'),
      ('public.zella_business_duplicates(text,text,text,uuid,uuid)', '59e78ac5dcdb883c0b7bf59256f0de5c')) as t(sig, want) loop
    if to_regprocedure(f.sig) is not null and md5(pg_get_functiondef(f.sig::regprocedure)) <> f.want then
      raise exception 'ROLLBACK_DRIFT: % has changed since this migration', f.sig;
    end if;
  end loop;
end $$;
drop function if exists public.zella_create_business_draft(jsonb, uuid);
drop function if exists public.zella_business_duplicates(text, text, text, uuid, uuid);
drop index if exists public.businesses_creation_key_key;
alter table public.businesses drop column if exists creation_key;
commit;
