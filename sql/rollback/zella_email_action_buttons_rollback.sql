-- Undoes sql/zella_email_action_buttons.sql exactly: the one line it added to zella_prepare_email is taken out again,
-- which gives back the exact version it found (either of sql/zella_business_email_send.sql's two), and the two new
-- functions go. zella_prepare_email must be exactly one of this file's two versions, and the new functions this file's
-- versions, otherwise ROLLBACK_DRIFT and nothing changes. Appointments already confirmed or cancelled with the buttons
-- stay as they are (customer data is never changed back). Emails sent from then on have no buttons; a ?do= link
-- already in a customer's inbox opens the reschedule page as before. Safe to run twice.
begin;
do $$
declare
  d text; v_new text; v_base text; f record;
  sig constant text := 'public.zella_prepare_email(uuid,uuid,text,jsonb,text)';
  -- this file's md5 -> the md5 it was applied to
  mine constant jsonb := jsonb_build_object(
    '80a0d034234f64a6384a6dd729d9681e', '5477af97583514bab9f3c3d6cffa98be',
    '48f63edd50fd20e6dfb921cc22c1b3ca', 'f6804f2eb7e698454e56669b0e5e31a4');
  news constant jsonb := '{
    "public.zella_reschedule_attend(text,text)": "531b1268be71d073fa117dd5a63b42f7",
    "public.zella_email_action_buttons(jsonb,text,text)": "f21a1a5b72e3494b310b1e69d750d68f"}';
  anchor constant text := $a$|| public.zella_business_email_sender(p_business_id);   /* zella_business_email_send: domain, mailbox or fallback */$a$;
  edit constant text := $w$|| public.zella_business_email_sender(p_business_id)   /* zella_business_email_send: domain, mailbox or fallback */
    || public.zella_email_action_buttons(p_vars, v_body, v_html);   /* zella_email_action_buttons: Confirm, Reschedule, Cancel */$w$;
begin
  if to_regclass('public.zella_function_archive') is null
     or not exists (select 1 from public.zella_function_archive where migration = 'zella_email_action_buttons') then
    return;   -- not applied, or already rolled back
  end if;
  d := pg_get_functiondef(sig::regprocedure);
  if not mine ? md5(d) then raise exception 'ROLLBACK_DRIFT: % has changed since this migration', sig; end if;
  for f in select key, value from jsonb_each_text(news) loop
    if to_regprocedure(f.key) is not null and md5(pg_get_functiondef(f.key::regprocedure)) <> f.value then
      raise exception 'ROLLBACK_DRIFT: % has changed since this migration', f.key;
    end if;
  end loop;
  v_base := mine ->> md5(d);
  v_new := replace(d, edit, anchor);
  if md5(v_new) <> v_base then raise exception 'ROLLBACK_DRIFT: % would not come back as the version it was', sig; end if;
  execute v_new;
  if md5(pg_get_functiondef(sig::regprocedure)) <> v_base then raise exception 'ROLLBACK_DRIFT: % did not come back as the version it was', sig; end if;
  delete from public.zella_function_archive where migration = 'zella_email_action_buttons';
end $$;
drop function if exists public.zella_email_action_buttons(jsonb, text, text);
drop function if exists public.zella_reschedule_attend(text, text);
commit;
