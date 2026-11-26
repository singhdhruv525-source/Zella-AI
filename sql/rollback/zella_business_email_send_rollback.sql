-- Undoes sql/zella_business_email_send.sql exactly: the one edit it made to each of zella_prepare_email and
-- zella_log_outbound_email is taken out again, which gives back the exact version it found (for zella_prepare_email
-- whichever of its two it was: production's, or production's with sql/zella_caller_verification.sql applied). Each
-- function must be exactly one of this file's versions first, otherwise ROLLBACK_DRIFT and nothing changes; the result
-- is checked against the version it maps to. Refuses (IN_USE) while sql/zella_email_action_buttons.sql is applied
-- (roll that back first). Customer emails then use the fallback sender again. Safe to run twice.
begin;
do $$
declare
  d text; v_new text; v_base text; f record;
  edits constant jsonb := jsonb_build_array(
    jsonb_build_object('sig', 'public.zella_prepare_email(uuid,uuid,text,jsonb,text)',
      -- this file's md5 -> the md5 it was applied to
      'mine', jsonb_build_object(
        '5477af97583514bab9f3c3d6cffa98be', '169dc4af51e2bff9f527bcb3fd9e7d84',
        'f6804f2eb7e698454e56669b0e5e31a4', 'd0d67a384b0e6a3e270e613ca4af923c'),
      'anchor', $a$'template_id', t.id, 'template_version', t.version, 'purpose', v_purpose);$a$,
      'edit', $w$'template_id', t.id, 'template_version', t.version, 'purpose', v_purpose)
    || public.zella_business_email_sender(p_business_id);   /* zella_business_email_send: domain, mailbox or fallback */$w$),
    jsonb_build_object('sig', 'public.zella_log_outbound_email(uuid,uuid,text,text,text,text,text,text,text,jsonb)',
      'mine', jsonb_build_object('3f878d87e3a4c13ee234b912b12f9e87', 'd524ef783e77b316130bc169d036f18c'),
      'anchor', $a$update public.email_messages set status = 'queued', updated_at = now() where id = r.id;$a$,
      'edit', $w$update public.email_messages set status = 'queued', updated_at = now(),   /* zella_business_email_send: what is sent this time */
           from_email = nullif(p_from, ''), to_email = p_to, subject = left(p_subject, 300), body_text = left(p_body_text, 20000), body_html = left(p_body_html, 40000),
           metadata = metadata || coalesce(p_meta, '{}'::jsonb) || jsonb_build_object('dedupe_key', p_dedupe_key)
     where id = r.id;$w$));
begin
  if to_regclass('public.zella_function_archive') is null
     or not exists (select 1 from public.zella_function_archive where migration = 'zella_business_email_send') then
    return;   -- not applied, or already rolled back
  end if;
  if position('zella_email_action_buttons' in pg_get_functiondef('public.zella_prepare_email(uuid,uuid,text,jsonb,text)'::regprocedure)) > 0 then
    raise exception 'IN_USE: roll back sql/zella_email_action_buttons.sql first';
  end if;
  -- check both first, then change both: all or nothing
  for f in select e ->> 'sig' as sig, e -> 'mine' as mine from jsonb_array_elements(edits) e loop
    if not f.mine ? md5(pg_get_functiondef(f.sig::regprocedure)) then raise exception 'ROLLBACK_DRIFT: % has changed since this migration', f.sig; end if;
  end loop;
  for f in select e ->> 'sig' as sig, e -> 'mine' as mine, e ->> 'anchor' as anchor, e ->> 'edit' as edit from jsonb_array_elements(edits) e loop
    d := pg_get_functiondef(f.sig::regprocedure);
    v_base := f.mine ->> md5(d);
    v_new := replace(d, f.edit, f.anchor);
    if md5(v_new) <> v_base then raise exception 'ROLLBACK_DRIFT: % would not come back as the version it was', f.sig; end if;
    execute v_new;
    if md5(pg_get_functiondef(f.sig::regprocedure)) <> v_base then raise exception 'ROLLBACK_DRIFT: % did not come back as the version it was', f.sig; end if;
  end loop;
  delete from public.zella_function_archive where migration = 'zella_business_email_send';
end $$;
commit;
