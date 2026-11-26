-- Zella Voice: Confirm, Reschedule and Cancel buttons in every appointment confirmation and reminder email (owner,
-- 26 Nov 2026; docs/ARCHITECTURE.md §14.4, "Replies"). The customer answers with a button that updates the CRM at once,
-- so no reply email has to be read. The buttons reuse the reschedule link the message already carries (/r/<code>,
-- sql/zella_reschedule.sql): one private code per appointment, only its hash stored, dead once the appointment has
-- passed or is cancelled. Mail scanners open links before people do (SEC-20), so a link never acts by being opened:
--   /r/<code>?do=confirm   the page asks "Confirm your visit?"; its button confirms it
--   /r/<code>              Reschedule, as today: pick a new time
--   /r/<code>?do=cancel    the page asks "Cancel your visit?"; its button cancels it
--   1. zella_reschedule_attend(code, 'confirm' | 'cancel'), for the reschedule-appointment edge function (server only):
--      the link must be valid and the appointment upcoming and booked (zella_reschedule_lookup, unchanged; a rebook link
--      for a missed visit can't confirm or cancel). Then zella_reminder_response does what a texted CONFIRM or CANCEL
--      does: confirmed (a second confirm says so and changes nothing), or cancelled with the reason "Canceled by the
--      customer from the email link"; the appointment trigger then withdraws its reminders, tells the team and offers
--      the time to the waitlist, as for any cancellation.
--   2. zella_email_action_buttons(vars, text, html): the three buttons, for an email whose values ask for them
--      (action_buttons = "true", set by the n8n Email Sender for confirmations and reminders) and carry a reschedule
--      link on Zella Voice's own app address. The plain text gets the three addresses; the HTML gets three buttons (one mocha primary, two outlined;
--      email clients can't read CSS variables, so the colours are tokens.css's hex values, as in businessEmails.js) in
--      place of the "Need a new time?" sentence, keeping the confirmation code. Without an app address
--      (app_base_url) there is no link, so no buttons: never a dead button.
--   3. zella_prepare_email merges the buttons into its answer, after the sender (sql/zella_business_email_send.sql).
-- zella_prepare_email is changed in place by one exact edit, archived first, and must be one of
-- sql/zella_business_email_send.sql's two versions (5477af97... on production's, f6804f2e... on caller verification's),
-- otherwise VERSION_MISMATCH and nothing changes. The two new functions must not exist in another version. Safe to run
-- twice. Rollback: sql/rollback/zella_email_action_buttons_rollback.sql
begin;

do $$
declare f record;
  mine constant jsonb := '{
    "public.zella_reschedule_attend(text,text)": "531b1268be71d073fa117dd5a63b42f7",
    "public.zella_email_action_buttons(jsonb,text,text)": "f21a1a5b72e3494b310b1e69d750d68f"}';
begin
  if to_regclass('public.appointment_reschedule_links') is null or to_regprocedure('public.zella_reschedule_lookup(text)') is null
     or to_regprocedure('public.zella_reminder_response(uuid,text,text)') is null or to_regclass('public.zella_function_archive') is null then
    raise exception 'VERSION_MISMATCH: something this file needs is missing (apply sql/zella_business_email_send.sql first)';
  end if;
  for f in select key, value from jsonb_each_text(mine) loop
    if to_regprocedure(f.key) is not null and md5(pg_get_functiondef(f.key::regprocedure)) <> f.value then
      raise exception 'VERSION_MISMATCH: % already exists in another version', f.key;
    end if;
  end loop;
end $$;

-- 1. a button pressed on the link's page (server only: reschedule-appointment, after its rate limits)
create or replace function public.zella_reschedule_attend(p_token text, p_action text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_info jsonb; l record; a record; v_res text;
begin
  if p_action is null or p_action not in ('confirm', 'cancel') then return jsonb_build_object('ok', false, 'reason', 'invalid'); end if;
  v_info := public.zella_reschedule_lookup(p_token);
  if not coalesce((v_info ->> 'ok')::boolean, false) then return v_info; end if;
  if v_info ? 'missed' and coalesce(v_info ->> 'missed', 'false') <> 'false' then
    return jsonb_build_object('ok', false, 'reason', 'not_available', 'business', v_info ->> 'business');
  end if;
  select x.* into l from public.appointment_reschedule_links x where x.token_hash = encode(sha256(convert_to(p_token, 'utf8')), 'hex');
  select x.id, x.status, x.start_time into a from public.appointments x where x.id = l.appointment_id and x.business_id = l.business_id for update;
  -- checked again under the row lock: still upcoming and still booked
  if a.id is null or a.status not in ('scheduled', 'confirmed') or a.start_time <= now() then
    return jsonb_build_object('ok', false, 'reason', 'not_available', 'business', v_info ->> 'business');
  end if;
  if p_action = 'confirm' then
    if a.status = 'confirmed' then
      v_res := 'already_confirmed';
    else
      perform public.zella_reminder_response(a.id, 'confirm', null);
      v_res := 'confirmed';
    end if;
  else
    perform public.zella_reminder_response(a.id, 'cancel', 'Canceled by the customer from the email link');
    v_res := 'cancelled';
  end if;
  update public.appointment_reschedule_links set last_used_at = now(), uses = uses + 1 where id = l.id;
  return jsonb_build_object('ok', true, 'result', v_res, 'business', v_info ->> 'business', 'timezone', v_info ->> 'timezone',
                            'appointment', v_info -> 'appointment');
end $$;

-- 2. the three buttons for one email (read only; server only)
create or replace function public.zella_email_action_buttons(p_vars jsonb, p_body_text text, p_body_html text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare m text[]; v_url text; v_html text;
  v_base text := regexp_replace(coalesce(nullif(trim(public.zella_setting('app_base_url', '""'::jsonb) #>> '{}'), ''), ''), '/+$', '');
  -- tokens.css: --zv-primary #70452F, --zv-border #E9E2D9, --zv-text #252321 (email clients can't read CSS variables)
  btn constant text := 'display:inline-block;padding:12px 20px;font-size:15px;font-weight:600;text-decoration:none';
begin
  if coalesce(p_vars ->> 'action_buttons', '') <> 'true' then return '{}'::jsonb; end if;
  -- the link the claim made (zella_reschedule_line): an https address, then /r/ and the 64 character code
  m := regexp_match(coalesce(p_vars ->> 'reschedule_line', ''), '(https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~-]+)*)/r/([0-9a-f]{64})(\s|$)');
  -- and only on Zella Voice's own app address (app_base_url), never anywhere else
  if m is null or m[1] is distinct from v_base then return '{}'::jsonb; end if;
  v_url := m[1] || '/r/' || m[4];
  -- the HTML's own "Need a new time?" sentence gives way to the buttons; the confirmation code before it stays
  v_html := regexp_replace(coalesce(p_body_html, ''), '\s?Need a new time\? https://[A-Za-z0-9./:_~-]+/r/[0-9a-f]{64}', '', 'g');
  v_html := v_html
    || '<table role="presentation" cellpadding="0" cellspacing="0" style="margin:20px 0 8px"><tr>'
    || '<td style="background:#70452F;border-radius:10px"><a href="' || v_url || '?do=confirm" style="' || btn || ';color:#FFFFFF">Confirm</a></td>'
    || '<td style="width:8px"></td>'
    || '<td style="border:1px solid #E9E2D9;border-radius:10px"><a href="' || v_url || '" style="' || btn || ';color:#252321">Reschedule</a></td>'
    || '<td style="width:8px"></td>'
    || '<td style="border:1px solid #E9E2D9;border-radius:10px"><a href="' || v_url || '?do=cancel" style="' || btn || ';color:#252321">Cancel</a></td>'
    || '</tr></table>';
  return jsonb_build_object('action_url', v_url,
    'body_text', coalesce(p_body_text, '') || E'\n\nConfirm: ' || v_url || '?do=confirm' || E'\nReschedule: ' || v_url || E'\nCancel: ' || v_url || '?do=cancel',
    'body_html', v_html);
end $$;

revoke all on function public.zella_reschedule_attend(text, text), public.zella_email_action_buttons(jsonb, text, text) from public, anon, authenticated;
grant execute on function public.zella_reschedule_attend(text, text), public.zella_email_action_buttons(jsonb, text, text) to service_role;

-- 3. zella_prepare_email adds them, after the sender
do $$
declare
  d text; v_new text; n integer; v_mine text;
  sig constant text := 'public.zella_prepare_email(uuid,uuid,text,jsonb,text)';
  -- base md5 -> this file's md5 on that base
  bases constant jsonb := jsonb_build_object(
    '5477af97583514bab9f3c3d6cffa98be', '80a0d034234f64a6384a6dd729d9681e',      -- sql/zella_business_email_send.sql on production's
    'f6804f2eb7e698454e56669b0e5e31a4', '48f63edd50fd20e6dfb921cc22c1b3ca');   -- the same on caller verification's
  anchor constant text := $a$|| public.zella_business_email_sender(p_business_id);   /* zella_business_email_send: domain, mailbox or fallback */$a$;
  edit constant text := $w$|| public.zella_business_email_sender(p_business_id)   /* zella_business_email_send: domain, mailbox or fallback */
    || public.zella_email_action_buttons(p_vars, v_body, v_html);   /* zella_email_action_buttons: Confirm, Reschedule, Cancel */$w$;
begin
  d := pg_get_functiondef(sig::regprocedure);
  if exists (select 1 from jsonb_each_text(bases) b where b.value = md5(d)) then return; end if;   -- already applied
  if not bases ? md5(d) then raise exception 'VERSION_MISMATCH: % is not a version this file was written for', sig; end if;
  v_mine := bases ->> md5(d);
  n := (length(d) - length(replace(d, anchor, ''))) / length(anchor);
  if n <> 1 then raise exception 'VERSION_MISMATCH: % anchor found % times', sig, n; end if;
  v_new := replace(d, anchor, edit);
  insert into public.zella_function_archive (migration, signature, definition, definition_md5)
  values ('zella_email_action_buttons', sig, d, md5(d)) on conflict (migration, signature) do nothing;
  execute v_new;
  if md5(pg_get_functiondef(sig::regprocedure)) <> v_mine then raise exception 'VERSION_MISMATCH: % did not come out as this file''s version', sig; end if;
end $$;

commit;
