-- Undoes sql/zella_caller_verification.sql exactly: the seven functions come back from zella_function_archive, and
-- the code trigger, the new functions and the three new tables are dropped (confirmation codes, failed checks and
-- contact changes waiting for the team are lost; customers and appointments are not touched). Each function must be
-- exactly this file's version first, otherwise ROLLBACK_DRIFT and nothing changes. Grants are kept (same signatures).
-- Safe to run twice.
begin;
do $$
declare a record;
  mine constant jsonb := jsonb_build_object(
    'public.zella_ai_tool(text,uuid,text,jsonb,text)',        '292cb59edd14074f69b90a74572ac16b',
    'public.zella_ai_manage_booking(text,uuid,text,jsonb)',  'a3458dc5c928b64995d154d7435a8f43',
    'public.zella_brain_tool_defs()',                        '858008c205ec3271a00bf375852ac646',
    'public.zella_brain_prompt_base(uuid)',                  '7ab9163c4df52183697bd8108aa94d15',
    'public.zella_claim_reminders(integer,text)',            '0025c2100523b5f21ec3ee7ba979208e',
    'public.zella_prepare_sms(uuid,uuid,text,jsonb,text)',   '038dad2c92525376fbeaf5e4964766a0',
    'public.zella_prepare_email(uuid,uuid,text,jsonb,text)', 'd0d67a384b0e6a3e270e613ca4af923c');
begin
  if to_regclass('public.zella_function_archive') is not null
     and exists (select 1 from public.zella_function_archive where migration = 'zella_caller_verification') then
    for a in select signature from public.zella_function_archive where migration = 'zella_caller_verification' loop
      if md5(pg_get_functiondef(a.signature::regprocedure)) <> mine ->> a.signature then
        raise exception 'ROLLBACK_DRIFT: % has changed since this migration', a.signature;
      end if;
    end loop;
    for a in select definition from public.zella_function_archive where migration = 'zella_caller_verification' loop
      execute a.definition;
    end loop;
    delete from public.zella_function_archive where migration = 'zella_caller_verification';
  end if;
end $$;
drop trigger if exists zella_confirmation_code_trg on public.appointments;
drop function if exists public.zella_confirmation_code_trg();
drop function if exists public.zella_customer_pending_change_decide(uuid, boolean);
drop function if exists public.zella_customer_pending_changes(uuid, uuid);
drop function if exists public.zella_caller_pending_change(uuid, uuid, text, text, text);
drop function if exists public.zella_code_sentence(text, text, jsonb);
drop function if exists public.zella_confirmation_code_line(uuid);
drop function if exists public.zella_confirmation_code_issue(uuid, uuid);
drop function if exists public.zella_confirmation_code_clean(text);
drop function if exists public.zella_confirmation_code_hash(uuid, text);
drop table if exists public.customer_pending_changes;
drop table if exists public.ai_call_verification_failures;
drop table if exists public.appointment_confirmation_codes;
commit;
