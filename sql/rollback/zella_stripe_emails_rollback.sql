-- Rollback of sql/zella_stripe_emails.sql: drops its triggers, table and functions (emails already in the platform outbox stay). Exact: refuses (ROLLBACK_DRIFT) if any function that file made differs from
-- its version, and (ROLLBACK_HAS_DATA) while rows that need it exist: nothing is deleted. Safe to run twice.
begin;

do $$
declare s text; v_has boolean;
  owned constant jsonb := '{
    "public.zella_usd_text(bigint)": "fcb6c7625eb245c5908a6345fac9aa6f",
    "public.zella_billing_email(uuid,text,text,text,jsonb)": "56d6fd452ad77eb83c5548f9cdeea526",
    "public.zella_billing_email_common(uuid)": "b6f8560d7cf2999a3379d966dceb7a02",
    "public.zella_billing_email_invoice_trg()": "cc75a8987f19e2ae96c066395b79af45",
    "public.zella_billing_email_subscription_trg()": "6129b20726a9fa4e7a24940582a5943b",
    "public.zella_billing_email_pack_trg()": "160bccec10e7dd48cdd6997409cb7f38",
    "public.zella_billing_email_sweep()": "262f5799f88c3da0aa51004a712431ae",
    "public.zella_billing_email_claim(integer)": "00fe89f6414d3f17fe4bdf9e0e901e14",
    "public.zella_billing_email_done(uuid,text,text)": "708c2cd8521deaba5ab51319ee942cd1"
  }';
begin
  for s in select jsonb_object_keys(owned) loop
    if to_regprocedure(s) is not null and md5(pg_get_functiondef(s::regprocedure)) <> owned ->> s then
      raise exception 'ROLLBACK_DRIFT: % is not the version zella_stripe_emails.sql made', s;
    end if;
  end loop;
  drop trigger if exists zella_billing_email_invoice on public.billing_invoices;
  drop trigger if exists zella_billing_email_subscription on public.subscriptions;
  drop trigger if exists zella_billing_email_pack on public.pack_purchases;
  if to_regclass('public.billing_email_intents') is not null then
    lock table public.billing_email_intents in access exclusive mode;   -- held until commit: no notice can be added before the drop
    -- any notice (waiting, held for a person, or already queued) is a record a person may need: refuse, delete nothing
    execute 'select exists (select 1 from public.billing_email_intents)' into v_has;
    if v_has then raise exception 'ROLLBACK_HAS_DATA: billing notices exist; a person decides what to keep'; end if;
  end if;
  for s in select jsonb_object_keys(owned) loop
    if to_regprocedure(s) is not null then execute format('drop function %s', s::regprocedure); end if;
  end loop;
end $$;
drop table if exists public.billing_email_intents;
commit;
