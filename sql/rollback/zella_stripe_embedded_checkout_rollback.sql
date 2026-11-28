-- Rollback of sql/zella_stripe_embedded_checkout.sql. Restores zella_billing_checkout_continue exactly as archived
-- (sql/zella_stripe_checkout.sql's version, which asks Stripe for its hosted page again) and drops
-- zella_billing_checkout_session. Refuses with ROLLBACK_DRIFT if either function differs from what the file made, and
-- with ROLLBACK_HAS_OPEN_CHECKOUT while any checkout is preparing, open or expiring: an in page (ui_mode custom) session has no hosted
-- page link, so it must be paid or expire first (a person decides). Nothing is deleted. Safe to run twice.
begin;

do $$
declare d text; v_open boolean;
  s constant text := 'public.zella_billing_checkout_continue(uuid,boolean)';
  v_orig constant text := '7f998f18370021b4668ce06f057d0055';
  v_made constant text := '9b3ed39a3089059057a2ef7c36a96a19';
begin
  if to_regprocedure(s) is null then raise exception 'ROLLBACK_DRIFT: % is missing', s; end if;
  if md5(pg_get_functiondef(s::regprocedure)) not in (v_orig, v_made) then
    raise exception 'ROLLBACK_DRIFT: % is not the version zella_stripe_embedded_checkout.sql made', s;
  end if;
  if to_regprocedure('public.zella_billing_checkout_session(uuid,uuid)') is not null then
    if md5(pg_get_functiondef(to_regprocedure('public.zella_billing_checkout_session(uuid,uuid)'))) <> '7099a2a798f3ef942e978b88111afa5d' then
      raise exception 'ROLLBACK_DRIFT: public.zella_billing_checkout_session(uuid,uuid) is not the version zella_stripe_embedded_checkout.sql made';
    end if;
  end if;
  if md5(pg_get_functiondef(s::regprocedure)) = v_made then
    lock table public.billing_checkouts in share row exclusive mode;   -- held until commit: no checkout starts meanwhile
    select exists (select 1 from public.billing_checkouts where status in ('preparing', 'open', 'expiring')) into v_open;
    if v_open then raise exception 'ROLLBACK_HAS_OPEN_CHECKOUT: a checkout is still open; it must be paid or expire first'; end if;
    select definition into d from public.zella_function_archive
     where migration = 'zella_stripe_embedded_checkout' and signature = s and definition_md5 = v_orig;
    if d is null then raise exception 'ROLLBACK_DRIFT: the archived % is missing', s; end if;
    execute d;
    if md5(pg_get_functiondef(s::regprocedure)) <> v_orig then raise exception 'ROLLBACK_DRIFT: % did not restore exactly', s; end if;
  end if;
  delete from public.zella_function_archive where migration = 'zella_stripe_embedded_checkout';
end $$;
do $$ begin
  if to_regprocedure('public.zella_billing_checkout_use_hosted(uuid)') is not null
     and md5(pg_get_functiondef(to_regprocedure('public.zella_billing_checkout_use_hosted(uuid)'))) <> 'edca4f087e575b0247e8e0b2c2b56b61' then
    raise exception 'ROLLBACK_DRIFT: public.zella_billing_checkout_use_hosted(uuid) is not the version zella_stripe_embedded_checkout.sql made';
  end if;
end $$;
drop function if exists public.zella_billing_checkout_session(uuid, uuid);
drop function if exists public.zella_billing_checkout_use_hosted(uuid);
alter table public.billing_checkouts drop column if exists ui_mode;
-- the restored function keeps the grants it had (create or replace keeps them): server only

commit;
