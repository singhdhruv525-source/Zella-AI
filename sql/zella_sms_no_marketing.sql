-- Zella - no marketing texts unless switched on (needed for Telnyx 10DLC "customer care" registration). Safe to run more than once.
-- Setting sms_marketing_allowed (default false). While it is false, any text marked marketing is refused with reason sms_marketing_off;
-- the same message can still go by email. Appointment, reply and follow-up texts are unaffected.
insert into public.platform_settings (key, value) values ('sms_marketing_allowed', 'false'::jsonb) on conflict (key) do nothing;
do $$
declare d text;
begin
  d := pg_get_functiondef('public.zella_prepare_sms(uuid,uuid,text,jsonb,text)'::regprocedure);
  if d not like '%sms_marketing_off%' then
    d := replace(d, E'  if v_purpose = ''marketing'' then\n    v_hour',
      E'  if v_purpose = ''marketing'' and coalesce(public.zella_setting(''sms_marketing_allowed'', ''false''::jsonb) = ''true''::jsonb, false) = false then\n    return jsonb_build_object(''allowed'', false, ''reason'', ''sms_marketing_off'', ''live'', v_live);\n  end if;\n  if v_purpose = ''marketing'' then\n    v_hour');
    if d not like '%sms_marketing_off%' then raise exception 'PATCH_FAILED_SMS_MARKETING'; end if;
    execute d;
  end if;
end $$;
