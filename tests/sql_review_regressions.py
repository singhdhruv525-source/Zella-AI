"""Run against a disposable PostgreSQL database: python3 tests/sql_review_regressions.py | psql -v ON_ERROR_STOP=1.
Fixtures model only dependencies of the reviewed functions; all changes roll back.
"""
from pathlib import Path
import re

SQL = Path(__file__).resolve().parents[1] / 'sql'
def function(file, name):
    source = (SQL / (file + '.sql')).read_text()
    match = re.search(r'create or replace function public\.' + name + r'\(.*?\$\$;', source, re.S)
    assert match, name
    return match[0]

def emit(sql):
    print(sql)

emit('''begin;
create schema auth;
create function auth.jwt() returns jsonb language sql as $$select current_setting('test.jwt', true)::jsonb$$;
create function auth.uid() returns uuid language sql as $$select (auth.jwt()->>'sub')::uuid$$;
create function auth.role() returns text language sql as $$select 'authenticated'::text$$;
create function public.check_ok(ok boolean, label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'FAIL: %', label; end if; end$$;
create table auth.users(id uuid primary key, email text, invited_at timestamptz, last_sign_in_at timestamptz);
create table auth.sessions(id uuid, user_id uuid);
create table auth.identities(user_id uuid, identity_data jsonb);
create table platform_admins(user_id uuid, is_active boolean);
insert into auth.users values ('00000000-0000-0000-0000-000000000001','owner@example.test',null,now());
insert into auth.sessions values ('00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000001');
insert into auth.identities values ('00000000-0000-0000-0000-000000000001','{"email":"owner@example.test","email_verified":true}');
select set_config('test.jwt','{"sub":"00000000-0000-0000-0000-000000000001","session_id":"00000000-0000-0000-0000-000000000002","email":"owner@example.test","amr":[{"method":"invite"}]}',true);
''')
emit(function('zella_invitation_hardening','zella_session_proved_email'))
emit(function('zella_invitation_hardening','zella_platform_admin_email_check'))
emit('''select check_ok(zella_session_proved_email(), 'email invite proof');
select set_config('test.jwt',jsonb_set(auth.jwt(),'{amr}','[{"method":"otp"}]')::text,true);
select check_ok(not zella_session_proved_email(), 'generic OTP denied even for verified email');
select set_config('test.jwt',jsonb_set(auth.jwt(),'{amr}','[{"method":"password"}]')::text,true);
select check_ok(not zella_session_proved_email(), 'password denied');
select set_config('test.jwt',jsonb_set(jsonb_set(auth.jwt(),'{amr}','[{"method":"invite"}]'),'{email}','"old@example.test"')::text,true);
select check_ok(not zella_session_proved_email(), 'stale email denied');
select set_config('test.jwt',jsonb_set(auth.jwt(),'{email}','"owner@example.test"')::text,true);
select set_config('test.jwt',auth.jwt()::text,true);
create trigger admin_check before insert or update on platform_admins for each row execute function zella_platform_admin_email_check();
insert into platform_admins values ('00000000-0000-0000-0000-000000000001',true);
update auth.identities set identity_data = identity_data || '{"email_verified":false}';
select check_ok(not zella_session_proved_email(), 'unverified identity denied');
do $$begin
  begin
    insert into platform_admins values ('00000000-0000-0000-0000-000000000001',true);
    raise exception 'unverified admin accepted';
  exception when insufficient_privilege then null; end;
end$$;
update auth.users set last_sign_in_at=null;
do $$begin
  begin
    insert into platform_admins values ('00000000-0000-0000-0000-000000000001',true);
    raise exception 'unsigned account accepted without invitation';
  exception when insufficient_privilege then null; end;
end$$;
update auth.users set invited_at=now();
insert into platform_admins values ('00000000-0000-0000-0000-000000000001',true);
create table businesses(id uuid, name text, timezone text);
create table platform_alerts(id uuid default gen_random_uuid(), status text default 'open', notified_at timestamptz, meta jsonb default '{}', kind text, severity text, title text, detail text, occurrences int, first_seen_at timestamptz default now(), last_seen_at timestamptz, business_id uuid);
create function zella_setting(text,jsonb) returns jsonb language sql as $$select case $1 when 'email_live' then 'true'::jsonb else '"sender@example.test"'::jsonb end$$;
''')
emit(function('zella_admin_alerts','zella_claim_admin_alert_email'))
emit(function('zella_admin_alerts','zella_finish_admin_alert_email'))
emit('''insert into platform_alerts(title,notified_at,meta,status) values
('new',null,'{}','open'), ('expired',now()-interval '16 minutes','{}','open'),
('live',now(),'{}','open'), ('sent',now()-interval '1 hour','{"emailed_at":"yesterday"}','open'),
('exhausted',now()-interval '1 hour','{"email_attempts":3}','open'), ('closed',null,'{}','closed');
select check_ok(jsonb_array_length(zella_claim_admin_alert_email()->'alerts')=2,'claim new and expired only');
select check_ok(jsonb_array_length(zella_claim_admin_alert_email()->'alerts')=0,'no immediate duplicate claims');
select zella_finish_admin_alert_email(array(select id from platform_alerts where title='new'),false,'test');
select check_ok(jsonb_array_length(zella_claim_admin_alert_email()->'alerts')=1,'failed send released');
create table message_templates(business_id uuid, industry_id uuid, key text, channel text, purpose text, locale text, subject text, body text, version int, status text);
insert into message_templates(key,channel,body) values ('test','sms','{{date}}');
insert into message_templates(business_id,key,channel,body) values (gen_random_uuid(),'test','sms','{{private}}');
''')
emit(function('zella_admin_ops','zella_admin_template_variables'))
emit('''select check_ok(zella_admin_template_variables('test','sms')=array['business','date','first_name'],'tenant template excluded');
create function zella_admin_reason(text) returns text language sql as $$select $1$$;
create function zella_admin_require(text) returns void language plpgsql as $$begin end$$;
''')
emit(function('zella_admin_ops','zella_admin_routing_save'))
emit('''do $$declare r jsonb; begin
 foreach r in array array[null::jsonb,'null','[]','"x"','1','true'] loop
  begin perform zella_admin_routing_save(null,r,'test'); raise exception 'invalid rules accepted';
  exception when raise_exception then if sqlerrm <> 'INVALID_RULES' then raise; end if; end;
 end loop;
end$$;
create table knowledge_items(id uuid default gen_random_uuid(), business_id uuid, kind text, title text, question text, answer text, status text, version int, error text, gap_id uuid, created_by uuid, approved_by uuid, approved_at timestamptz, ready_at timestamptz, updated_at timestamptz);
''')
emit(function('zella_knowledge','zella_knowledge_guard'))
emit('''create trigger guard before insert or update on knowledge_items for each row execute function zella_knowledge_guard();
insert into knowledge_items(title,status,approved_by,approved_at) values ('draft','draft',gen_random_uuid(),now());
select check_ok(approved_by is null and approved_at is null,'draft approval cleared') from knowledge_items;
update knowledge_items set approved_by=gen_random_uuid(),approved_at=now();
select check_ok(approved_by is null and approved_at is null,'approval forgery blocked') from knowledge_items;
update knowledge_items set status='processing';
select check_ok(approved_by=auth.uid() and approved_at is not null,'processing approval retained') from knowledge_items;
create table customers(id uuid,first_name text,last_name text);
insert into customers values ('00000000-0000-0000-0000-000000000003','Test','Customer');
create table followup_tasks(business_id uuid,customer_id uuid,kind text,channel text,due_at timestamptz,max_attempts int,created_at timestamptz default now());
create table contact_consents(business_id uuid,phone_digits text,channel text,status text);
create table sms_messages(business_id uuid,customer_id uuid,direction text,status text,from_number text,message_body text,metadata jsonb,created_at timestamptz default now());
create function zella_match_customer(uuid,text,text) returns table(customer_id uuid,certainty text) language sql as $$select id,'exact'::text from customers where $2='known'$$;
create function zella_business_open(uuid,timestamptz) returns jsonb language sql as $$select '{"open":false}'::jsonb$$;
create function zella_digits(text) returns text language sql as $$select $1$$;
create function zella_record_consent(uuid,text,text,text,uuid,text,text,text,text) returns void language plpgsql as $$begin end$$;
create function zella_notify_owners(uuid,text,text,text,text,text) returns void language plpgsql as $$begin end$$;
''')
patch=(SQL/'zella_after_hours_reply.sql').read_text()
for file, action in [('zella_automation_foundation','none'),('zella_inbound_replies','reply_received')]:
    emit(function(file,'zella_handle_inbound_sms_keyword'))
    emit(patch)
    emit(patch)  # rerun must be safe
    emit(f'''truncate followup_tasks;
select check_ok(zella_handle_inbound_sms_keyword(null,'known','STOP')->>'action'='opted_out','STOP unchanged');
select check_ok((select count(*)=0 from followup_tasks),'STOP queues no after hours reply');
select check_ok(zella_handle_inbound_sms_keyword(null,'unknown','hello')->>'action'='{action}','ordinary action unchanged');
select check_ok((zella_handle_inbound_sms_keyword('00000000-0000-0000-0000-000000000004','known','hello')->>'after_hours_reply_queued')::boolean,'after hours queued');
select check_ok(not coalesce((zella_handle_inbound_sms_keyword('00000000-0000-0000-0000-000000000004','known','hello')->>'after_hours_reply_queued')::boolean,false),'12 hour suppression');
''')
emit("""
create table industry_automation_presets(industry_key text,name text,description text,trigger_type text,trigger_config jsonb);
create table automations(id uuid default gen_random_uuid(),business_id uuid,name text,description text,trigger_type text,status text,trigger_config jsonb,actions jsonb,conditions jsonb,created_by uuid,updated_at timestamptz);
create table audit_logs(business_id uuid,user_id uuid,action text,entity_type text,new_data jsonb);
create function is_platform_admin() returns boolean language sql as $$select true$$;
create function zella_has_role(uuid,text[]) returns boolean language sql as $$select true$$;
create function zella_industry_key_for(uuid) returns text language sql as $$select 'test'::text$$;
insert into industry_automation_presets values ('test','Rule','description','test','{"notify_via":"email","keep":1}');
""")
emit(function('zella_industry_rule_list','zella_set_industry_rules'))
emit("""
select zella_set_industry_rules('00000000-0000-0000-0000-000000000004','[{"name":"Rule","enabled":false}]');
select check_ok(trigger_config='{"notify_via":"email","keep":1}'::jsonb,'missing channel preserves preset') from automations;
select zella_set_industry_rules('00000000-0000-0000-0000-000000000004','[{"name":"Rule","notify_via":"invalid"}]');
select check_ok(trigger_config='{"notify_via":"email","keep":1}'::jsonb,'invalid channel preserves existing') from automations;
select zella_set_industry_rules('00000000-0000-0000-0000-000000000004','[{"name":"Rule","notify_via":"sms"}]');
select check_ok(trigger_config='{"notify_via":"sms","keep":1}'::jsonb,'valid channel updates') from automations;
create table industries(id uuid,name text);
alter table businesses add column industry_id uuid;
create table industry_crm_presets(key text,match text[]);
insert into industries values ('00000000-0000-0000-0000-000000000005','Test');
insert into businesses(id,industry_id) values ('00000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-000000000005');
insert into industry_crm_presets values ('test',array['test']);
insert into industry_automation_presets values ('test','New rule','description','test','{}');
""")
for file in ['zella_industry_engine','zella_automation_completion']:
    emit(function(file,'zella_apply_industry_automations'))
    emit("""delete from automations where name='New rule';
select zella_apply_industry_automations('00000000-0000-0000-0000-000000000004');
select check_ok(status='disabled','new rules disabled') from automations where name='New rule';
select check_ok(status='active','existing rule status preserved') from automations where name='Rule';
""")
emit("""select check_ok('{"body":"secret","text":"secret","keep":1}'::jsonb - 'body' - 'text' = '{"keep":1}'::jsonb,'metadata strips only content');""")
emit('rollback;')
