-- Zella Voice: customer-, owner- and admin-facing wording names the brand in full ("Zella Voice", not "Zella")
-- wherever the brand itself is named: email sender names and subjects, welcome and setup messages, the staff text
-- prefix, calendar event notes, the public status page and a few notices. Running sentences that use the short
-- form ("Zella tried …", "Zella could not answer …") are left as they are, per the naming rule.
-- Function bodies only (one string each, listed below); no table data. Nothing changes for a live call except the
-- wording of one notice the business sees when its receptionist is misconfigured (zella_assistant_for_call).
-- Version guard: each function is patched only if its body still matches production as read on 9 Nov 2026 (md5),
-- otherwise it stops with "has changed; review this patch". Already patched = skipped, so it is safe to run again.
-- Rollback: sql/rollback/zella_brand_name_rollback.sql
-- Validation (expect 0 rows):
--   select f, o from zella_brand_name_pairs() x(f, h, o, n) join pg_proc p on p.proname = x.f where p.prosrc not like '%' || x.n || '%';

create or replace function public.zella_brand_name_pairs()
returns table (fn text, md5_before text, old_text text, new_text text) language sql immutable set search_path = public as $$
  values
    ('zella_claim_owner_emails',      '2cb20771657a288b48d673da3477b31a', '''from_name'', ''Zella''',            '''from_name'', ''Zella Voice'''),
    ('zella_claim_owner_emails',      '2cb20771657a288b48d673da3477b31a', 'Open Zella to see the details.',      'Open Zella Voice to see the details.'),
    ('zella_claim_admin_alert_email', '66ec3be2abc0cc68eaf0758031f0ad30', '''from_name'', ''Zella''',            '''from_name'', ''Zella Voice'''),
    ('zella_business_welcome',        'fa7f4f41f6e0137fe19e9b099e4bf119', '''Welcome to Zella - ',               '''Welcome to Zella Voice - '),
    ('zella_check_connections',       '3a55c9dbe65734f379ff12407bb724d1', 'Finish setting up Zella''',           'Finish setting up Zella Voice'''),
    ('zella_check_setup_incomplete',  '088d522c85f0f4eb1240bf7d309af4cd', 'Finish setting up Zella''',           'Finish setting up Zella Voice'''),
    ('zella_check_trials',            '1805890209e86546e8adb4f1ac3911ad', 'keep using Zella.',                   'keep using Zella Voice.'),
    ('zella_claim_calendar_sync',     '01219c987442b1e4a595a953b8c6156a', 'Booked with Zella.',                  'Booked with Zella Voice.'),
    ('zella_claim_staff_sms',         'fd88e0265395067625d220b302b238cd', '''Zella: ''',                         '''Zella Voice: '''),
    ('zella_post_weekly_reviews',     '5ec70e1574a5bc9b9af48c0dd495cc88', 'Your week with Zella''',              'Your week with Zella Voice'''),
    ('zella_report_build',            'c32567f0ee41e4c852a746ba6556a4b3', 'Your day with Zella - ',              'Your day with Zella Voice - '),
    ('zella_assistant_for_call',      'b28086f063b3cae1b1869fbcc6c2db06', 'The Zella team has been told',        'The Zella Voice team has been told'),
    ('zella_public_status',           '242cfb8d505013be6aafe802f94f3d64', '''Zella app''',                       '''Zella Voice app'''),
    ('zella_spam_assess',             '1fc93d6a3222ab888ac28348a7291154', 'a Zella platform block rule',         'a Zella Voice platform block rule'),
    ('zella_spam_finish_work',        'e13ac912d10ded96086b1985ef57b772', 'business(es) on Zella this month',    'business(es) on Zella Voice this month'),
    ('zella_subscription_after',      'de4816583fc95a5f678f3bbc408ac814', 'to keep Zella running',               'to keep Zella Voice running'),
    ('zella_security_log',            'fb4a4f3f00d04c15074907b86ce61f41', ', ''Zella''))',                       ', ''Zella Voice''))')
$$;
revoke all on function public.zella_brand_name_pairs() from public, anon, authenticated;

do $$
declare f record; x record; v_def text;
begin
  for f in select distinct p.oid, p.proname, md5(p.prosrc) as h, p.prosrc
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             join public.zella_brand_name_pairs() b on b.fn = p.proname
            where n.nspname = 'public'
  loop
    -- already patched (every new text present): skip
    continue when not exists (select 1 from public.zella_brand_name_pairs() b
                               where b.fn = f.proname and position(b.new_text in f.prosrc) = 0);
    if f.h <> (select min(b.md5_before) from public.zella_brand_name_pairs() b where b.fn = f.proname) then
      raise exception '% has changed; review this patch', f.proname;
    end if;
    v_def := pg_get_functiondef(f.oid);
    for x in select b.old_text, b.new_text from public.zella_brand_name_pairs() b where b.fn = f.proname loop
      if position(x.old_text in v_def) = 0 then raise exception '%: text not found: %', f.proname, x.old_text; end if;
      v_def := replace(v_def, x.old_text, x.new_text);
    end loop;
    execute v_def;
  end loop;
end $$;
