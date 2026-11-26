-- Zella Voice: the business's own email address, part 2: customer emails use it (owner, 26 Nov 2026;
-- docs/ARCHITECTURE.md §14.4). Needs sql/zella_business_email.sql.
--   1. zella_prepare_email (every email to a customer: confirmations, reminders, follow ups, marketing) adds who sends
--      it: its answer is merged with zella_business_email_sender(business), so from, from_name and reply_to are the
--      business's verified domain address (through Resend), its connected mailbox (through Gmail or Microsoft Graph),
--      or the fallback "<business name> <email_from_address>" with Reply-To the business email; the answer also says
--      sender_route, transport and sender_note. Replies go to the business's own inbox (owner, 26 Nov 2026): the
--      fallback's Reply-To is the business email, no longer the inbound address. Everything else (consent, the plan
--      limit, template, safe HTML, unsubscribe) is unchanged, and nothing is sent from here. While both
--      business_email_routes switches are off (as they start), every business uses the fallback.
--   2. zella_log_outbound_email: when a failed email is tried again under the same key (a reminder retried after a
--      mailbox refusal goes out through the fallback), the row now records what is sent this time (from, to, subject,
--      bodies, and the new details such as the transport), so the record is true and today's mailbox count stays right.
-- Both are changed in place by one exact edit each, archived first. zella_prepare_email must be production's version
-- (169dc4af..., 18 Nov 2026) or that version with sql/zella_caller_verification.sql applied (d0d67a38...); the edit
-- does not overlap caller verification's. (Caller verification checks for those two versions only, so it is applied
-- before this file, or its guard is given this file's version first.) zella_log_outbound_email must be production's
-- (d524ef78..., sql/zella_email_sender.sql). Otherwise VERSION_MISMATCH and nothing changes. Safe to run twice.
-- Rollback: sql/rollback/zella_business_email_send_rollback.sql
begin;

do $$
begin
  if to_regprocedure('public.zella_business_email_sender(uuid)') is null
     or md5(pg_get_functiondef(to_regprocedure('public.zella_business_email_sender(uuid)'))) <> '193583411ec9519f57a68684c7ebf224' then
    raise exception 'VERSION_MISMATCH: apply sql/zella_business_email.sql first (zella_business_email_sender is missing or another version)';
  end if;
end $$;

create table if not exists public.zella_function_archive (
  migration text not null,
  signature text not null,
  definition text not null,
  definition_md5 text not null,
  saved_at timestamptz not null default now(),
  primary key (migration, signature)
);
alter table public.zella_function_archive enable row level security;
revoke all on table public.zella_function_archive from public, anon, authenticated;

do $$
declare
  d text; v_new text; n integer; v_mine text; f record;
  edits constant jsonb := jsonb_build_array(
    jsonb_build_object('sig', 'public.zella_prepare_email(uuid,uuid,text,jsonb,text)',
      -- base md5 -> this file's md5 on that base
      'bases', jsonb_build_object(
        '169dc4af51e2bff9f527bcb3fd9e7d84', '5477af97583514bab9f3c3d6cffa98be',        -- production (zella_usage_enforcement applied)
        'd0d67a384b0e6a3e270e613ca4af923c', 'f6804f2eb7e698454e56669b0e5e31a4'),     -- production with zella_caller_verification applied
      'anchor', $a$'template_id', t.id, 'template_version', t.version, 'purpose', v_purpose);$a$,
      'edit', $w$'template_id', t.id, 'template_version', t.version, 'purpose', v_purpose)
    || public.zella_business_email_sender(p_business_id);   /* zella_business_email_send: domain, mailbox or fallback */$w$),
    jsonb_build_object('sig', 'public.zella_log_outbound_email(uuid,uuid,text,text,text,text,text,text,text,jsonb)',
      'bases', jsonb_build_object('d524ef783e77b316130bc169d036f18c', '3f878d87e3a4c13ee234b912b12f9e87'),
      'anchor', $a$update public.email_messages set status = 'queued', updated_at = now() where id = r.id;$a$,
      'edit', $w$update public.email_messages set status = 'queued', updated_at = now(),   /* zella_business_email_send: what is sent this time */
           from_email = nullif(p_from, ''), to_email = p_to, subject = left(p_subject, 300), body_text = left(p_body_text, 20000), body_html = left(p_body_html, 40000),
           metadata = metadata || coalesce(p_meta, '{}'::jsonb) || jsonb_build_object('dedupe_key', p_dedupe_key)
     where id = r.id;$w$));
begin
  for f in select e ->> 'sig' as sig, e -> 'bases' as bases, e ->> 'anchor' as anchor, e ->> 'edit' as edit from jsonb_array_elements(edits) e loop
    if to_regprocedure(f.sig) is null then raise exception 'VERSION_MISMATCH: % is missing', f.sig; end if;
    d := pg_get_functiondef(f.sig::regprocedure);
    if exists (select 1 from jsonb_each_text(f.bases) b where b.value = md5(d)) then continue; end if;   -- already applied
    if not f.bases ? md5(d) then raise exception 'VERSION_MISMATCH: % is not a version this file was written for', f.sig; end if;
    v_mine := f.bases ->> md5(d);
    n := (length(d) - length(replace(d, f.anchor, ''))) / length(f.anchor);
    if n <> 1 then raise exception 'VERSION_MISMATCH: % anchor found % times', f.sig, n; end if;
    v_new := replace(d, f.anchor, f.edit);
    insert into public.zella_function_archive (migration, signature, definition, definition_md5)
    values ('zella_business_email_send', f.sig, d, md5(d)) on conflict (migration, signature) do nothing;
    execute v_new;
    if md5(pg_get_functiondef(f.sig::regprocedure)) <> v_mine then
      raise exception 'VERSION_MISMATCH: % did not come out as this file''s version', f.sig;
    end if;
  end loop;
end $$;

commit;
