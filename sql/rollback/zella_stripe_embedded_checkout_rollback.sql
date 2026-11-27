-- Rollback of sql/zella_stripe_embedded_checkout.sql. Restores zella_billing_checkout_continue exactly as archived
-- (sql/zella_stripe_checkout.sql's version, which asks Stripe for its hosted page again) and drops
-- zella_billing_checkout_session. Refuses with ROLLBACK_DRIFT if either function differs from what the file made, and
-- with ROLLBACK_HAS_OPEN_CHECKOUT while any checkout is preparing, open or expiring: an embedded session has no hosted
-- page link, so it must be paid or expire first (a person decides). Nothing is deleted. Safe to run twice.
begin;

do $$
declare d text; v_open boolean;
  s constant text := 'public.zella_billing_checkout_continue(uuid,boolean)';
  v_orig constant text := '7f998f18370021b4668ce06f057d0055';
  v_made constant text := '79461b5217457813a6747d7b2f6e8fb8';
begin
  if to_regprocedure(s) is null then raise exception 'ROLLBACK_DRIFT: % is missing', s; end if;
  if md5(pg_get_functiondef(s::regprocedure)) not in (v_orig, v_made) then
    raise exception 'ROLLBACK_DRIFT: % is not the version zella_stripe_embedded_checkout.sql made', s;
  end if;
  if to_regprocedure('public.zella_billing_checkout_session(uuid,uuid)') is not null then
    if md5(pg_get_functiondef(to_regprocedure('public.zella_billing_checkout_session(uuid,uuid)'))) <> '4338711a1aad11ba1b708695aaf122fb' then
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
drop function if exists public.zella_billing_checkout_session(uuid, uuid);
-- the restored function keeps the grants it had (create or replace keeps them): server only

commit;
