"""Run with ZELLA_TEST_DSN pointing to a disposable PostgreSQL database.
CodeRabbit regression fixtures: no production data; every scenario rolls back.
"""
import os
import re
from pathlib import Path
import psycopg
from pglast import parse_sql
SQL = Path(__file__).resolve().parents[1] / 'sql'
def source(file): return (SQL / (file + '.sql')).read_text()
def function(file, name):
    return re.search(r'create or replace function public\.' + name + r'\(.*?\$\$;', source(file), re.S)[0]
def block(file, tag):
    return re.search(r'do \$'+tag+r'\$.*?end \$'+tag+r'\$;', source(file), re.S)[0]
with psycopg.connect(os.environ['ZELLA_TEST_DSN']) as db:
    def run(sql, args=None): return db.execute(sql,args)
    def value(sql,args=None): return run(sql,args).fetchone()[0]
    def rejects(sql, expected):
        try:
            with db.transaction(): run(sql)
        except psycopg.Error as e: assert expected in str(e),str(e)
        else: raise AssertionError('Expected '+expected)
    for file in SQL.rglob('*.sql'): parse_sql(file.read_text())
    print('PASS all migrations parse')
    for role in ['anon','authenticated','service_role']:
        if not value('select exists(select 1 from pg_roles where rolname=%s)',(role,)):
            run('create role '+role)
    with db.transaction(force_rollback=True):
        run('create table businesses(id uuid primary key)')
        for table in ['automation_events','automation_dead_letters']:
            run(re.search(r'create table if not exists public\.'+table+r' \(.*?\n\);',source('zella_automation_foundation'),re.S)[0])
        run(function('zella_automation_foundation','zella_redact'))
        run(function('zella_automation_foundation','zella_claim_events'))
        run(function('zella_automation_foundation','zella_complete_event'))
        biz=value('insert into businesses values(gen_random_uuid()) returning id')
        event=value("insert into automation_events(business_id,event_type,source,idempotency_key) values(%s,'test.event','system','test-event') returning id",(biz,))
        token=value('select claimed_at from zella_claim_events(10)')
        assert token is not None
        assert value("select zella_complete_event(%s,true,%s::timestamptz-interval '1 second')",(event,token))=='ignored'
        assert value('select zella_complete_event(%s,true,%s)',(event,token))=='processed'
        assert value('select zella_complete_event(%s,true,%s)',(event,token))=='ignored'
        run("update automation_events set status='processing',attempts=5,claimed_at=now()-interval '20 minutes'")
        assert value('select count(*) from zella_claim_events(10)')==0
        assert value('select status from automation_events')=='failed'
        assert value('select count(*) from automation_dead_letters')==1
        print('PASS event leases reject stale and duplicate reports; exhausted claims dead-letter')
    with db.transaction(force_rollback=True):
        run('create schema auth; create function auth.uid() returns uuid language sql as $$select null::uuid$$')
        run('create function zella_has_role(uuid,text[]) returns boolean language sql as $$select true$$')
        run('create table appointments(id uuid, customer_id uuid, record_id uuid); create table crm_records(id uuid,customer_id uuid)')
        run(function('zella_appointment_records','zella_appointment_record_match_trg'))
        for table,trig in [('appointments','zella_appointment_record_match'),('crm_records','zella_record_appointment_match')]:
            run(f'create constraint trigger {trig} after update of customer_id on {table} deferrable initially deferred for each row execute function zella_appointment_record_match_trg()')
        run("insert into crm_records values('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000002'); insert into appointments select gen_random_uuid(),customer_id,id from crm_records")
        rejects('update crm_records set customer_id=gen_random_uuid(); set constraints all immediate','RECORD_OTHER_CUSTOMER')
        run("update crm_records set customer_id='00000000-0000-0000-0000-000000000003'; update appointments set customer_id='00000000-0000-0000-0000-000000000003'; set constraints all immediate")
        print('PASS deferred record/customer check rejects mismatch and accepts atomic merge')
    with db.transaction(force_rollback=True):
        run('create table calendar_connections(id uuid, business_id uuid,status text,provider text); create table blocked_times(connection_id uuid,source text,end_time timestamptz)')
        run(function('zella_calendar_sync','zella_replace_calendar_busy'))
        run("insert into calendar_connections values ('00000000-0000-0000-0000-000000000001',gen_random_uuid(),'active','outlook'); insert into blocked_times select id,provider,now() from calendar_connections")
        rejects("select zella_replace_calendar_busy('00000000-0000-0000-0000-000000000001',(select jsonb_agg('{}'::jsonb) from generate_series(1,501)))",'TOO_MANY_EVENTS')
        assert value('select count(*) from blocked_times')==1
        print('PASS oversized calendar import rejected before deleting busy blocks')
    with db.transaction(force_rollback=True):
        run('create schema auth; create function auth.uid() returns uuid language sql as $$select gen_random_uuid()$$')
        run('create function zella_has_role(uuid,text[]) returns boolean language sql as $$select true$$')
        run(function('zella_business_settings','zella_save_business_hours'))
        rejects("select zella_save_business_hours(null,'[{\"weekday\":\"01\",\"opens\":\"09:00\",\"closes\":\"11:00\"},{\"weekday\":1,\"opens\":\"10:00\",\"closes\":\"12:00\"}]')",'HOURS_OVERLAP')
        print('PASS equivalent weekday representations overlap')
    with db.transaction(force_rollback=True):
        # Test captures against existing functions and grants, then against absent functions.
        run('create function zella_set_attendance(uuid,text,text,uuid) returns text language sql as $$select \'prior\'::text$$; revoke all on function zella_set_attendance(uuid,text,text,uuid) from public; grant execute on function zella_set_attendance(uuid,text,text,uuid) to anon with grant option')
        run('create table appointments(id uuid,arrived_at timestamptz)')
        pre=source('zella_attendance').split('-- Attendance tracking:')[0]
        run(pre);run(pre)
        run("create or replace function zella_set_attendance(uuid,text,text,uuid) returns text language sql as $$select 'changed'::text$$")
        for c in ['in_service_at','attendance_source','attendance_by','attendance_note']:
            run('alter table appointments add column '+c+' text')
        undo=source('rollback/zella_attendance_rollback').split('begin;',1)[1].rsplit('commit;',1)[0]
        run(undo)
        assert value('select zella_set_attendance(null,null,null,null)')=='prior'
        assert value("select has_function_privilege('anon','zella_set_attendance(uuid,text,text,uuid)','execute')")
        assert value("select count(*) from information_schema.columns where table_name='appointments'")==2
        print('PASS attendance rollback restores prior function/grants and preserves preexisting column')
    with db.transaction(force_rollback=True):
        run('create schema storage; create table storage.objects(bucket_id text,name text)')
        run('create function zella_can_write_brand_asset(text) returns boolean language sql as $$select true$$')
        for existed in [False,True]:
            if existed: run('create policy brand_assets_select on storage.objects for select to anon using(false)')
            run(source('zella_brand_assets_select'));run(source('zella_brand_assets_select'))
            run(source('rollback/zella_brand_assets_select_rollback').split('begin;',1)[1].rsplit('commit;',1)[0])
            assert value("select count(*) from pg_policies where policyname='brand_assets_select'")==int(existed)
            if existed: assert value("select qual from pg_policies where policyname='brand_assets_select'")=='false'
        print('PASS brand policy rollback preserves original policy or removes only newly created policy')
    with db.transaction(force_rollback=True):
        # Both absent-table and duplicate-policy variants must be safe.
        run('create schema auth; create function auth.uid() returns uuid language sql as $$select null::uuid$$')
        run(source('zella_db_fixes'));run(source('zella_db_fixes'))
        run(source('rollback/zella_db_fixes_rollback').split('begin;',1)[1].rsplit('commit;',1)[0])
        run('create table agent_config_versions(business_id uuid); create function zella_is_member(uuid) returns boolean language sql as $$select true$$')
        run('create policy agent_config_versions_select on agent_config_versions for select to authenticated using(zella_is_member(business_id)); create policy agent_config_versions_read on agent_config_versions for select to anon using(zella_is_member(business_id))')
        run(source('zella_db_fixes'))
        assert value("select count(*) from pg_policies where tablename='agent_config_versions'")==2
        print('PASS database fixes tolerate absent tables and retain policies with different roles')
    # Use the actual expression to check DST, without depending on the session timezone.
    expr=re.search(r'v_end := (.*?);',source('zella_capabilities'))[1]
    for day,hours in [('2026-03-08',23),('2026-11-01',25)]:
        end=expr.replace('now()',f"'{day} 12:00+00'::timestamptz").replace('v_tz',"'America/New_York'")
        assert value(f"select extract(epoch from ({end} - '{day}'::timestamp at time zone 'America/New_York'))/3600")==hours
    print('PASS local-day windows span 23/25 hours across DST')
    with db.transaction(force_rollback=True):
        run(function('zella_ai_booking','zella_ai_booking'))
        run(block('zella_arrival_windows',''))
        run(block('zella_arrival_windows',''))
        definition=value("select pg_get_functiondef('zella_ai_booking(text,uuid,text,jsonb)'::regprocedure)")
        assert definition.count('v_window integer;')==1
        for key,default,lo,hi in [('duration_minutes',30,5,480),('days',3,1,14)]:
            var='v_dur' if key=='duration_minutes' else 'v_days'
            fragment=re.search(var+r' := '+str(default)+r';.*?end if;',source('zella_ai_booking'),re.S)[0]
            run(f"create function test_{key}(v_args jsonb) returns integer language plpgsql as $$declare {var} integer; begin {fragment} return {var}; end$$")
            for raw,expected in [(None,default),('bad',default),('1.5',default),('99999999999999999',default),('2147483647',hi),('-2147483648',lo),('10',min(hi,10))]:
                assert value(f'select test_{key}(jsonb_build_object(%s::text,%s::text))',(key,raw))==expected
        print('PASS booking integer validation/bounds and arrival-window declaration rerun')
    with db.transaction(force_rollback=True):
        run('create function zella_brain_context(uuid) returns jsonb language sql as $$select \'{"business":{"industry_key":"other","industry":"Other","timezone":"UTC","name":"Test"},"agent":{"name":"Receptionist"},"hours":[],"closures":[],"knowledge_topics":[]}\'::jsonb$$')
        run(function('zella_brain','zella_brain_prompt_base'))
        run(block('zella_brain','install'))
        assert value('select zella_brain_prompt(null)')
        run('create table live_notices(business_id uuid, message text,created_at timestamptz,cleared_at timestamptz,ends_at timestamptz)')
        run("insert into live_notices values('00000000-0000-0000-0000-000000000001','NOTICE TEST',now(),null,now()+interval '1 hour')")
        run(function('zella_automation_completion','zella_brain_prompt'))
        run(function('zella_brain','zella_brain_prompt_base'));run(block('zella_brain','install'))
        assert 'NOTICE TEST' in value("select zella_brain_prompt('00000000-0000-0000-0000-000000000001')")
        run("create function zella_owner_rules_prompt(uuid,text) returns text language sql as $$select 'OWNER '||$2$$")
        text=value("select zella_brain_prompt('00000000-0000-0000-0000-000000000001')")
        assert 'OWNER transfer' in text and 'OWNER rules' in text
        print('PASS brain rerun preserves notice wrapper and current owner rules')
    with db.transaction(force_rollback=True):
        # The actual migration blocks must retain newer installed implementations.
        for install in re.findall(r'do \$install\$.*?end \$install\$;', source('zella_assistant_delivery'),re.S): run(install)
        run(block('zella_delivery_evidence',''))
        patched=value("select pg_get_functiondef('zella_assistant_for_call(text,text,text)'::regprocedure)")
        assert "md5((v_cfg - 'ready_to_send' - 'problems')::text)" in patched
        run(function('zella_delivery_evidence','zella_assistant_delivery_status'))
        status=value("select pg_get_functiondef('zella_assistant_delivery_status(uuid)'::regprocedure)")
        for install in re.findall(r'do \$install\$.*?end \$install\$;', source('zella_assistant_delivery'),re.S): run(install)
        assert value("select pg_get_functiondef('zella_assistant_for_call(text,text,text)'::regprocedure)")==patched
        assert value("select pg_get_functiondef('zella_assistant_delivery_status(uuid)'::regprocedure)")==status
        print('PASS assistant delivery rerun preserves evidence and status definitions')
    with db.transaction(force_rollback=True):
        run(block('zella_followup_texts','install'))
        run(function('zella_followup_emails','zella_claim_followup_texts'))
        later=value("select pg_get_functiondef('zella_claim_followup_texts(integer,text[])'::regprocedure)")
        run(block('zella_followup_texts','install'))
        assert value("select pg_get_functiondef('zella_claim_followup_texts(integer,text[])'::regprocedure)")==later
        definition=function('zella_inbound_replies','zella_claim_followup_texts').replace('public.zella_claim_followup_texts(','public.zella_claim_followup_texts_base(')
        run(definition)
        patch='--'+source('zella_customer_touches').split('-- 9. Fix:')[1]
        run(patch);run(patch)
        patched=value("select pg_get_functiondef('zella_claim_followup_texts_base(integer,text[])'::regprocedure)")
        assert patched.count('zella_customer_touches_offer_reset')==1
        print('PASS later consent-aware claim retained; unique task-loop patch reruns safely')
    with db.transaction(force_rollback=True):
        run("create schema auth; create function auth.uid() returns uuid language sql as $$select '00000000-0000-0000-0000-000000000001'::uuid$$; create function auth.role() returns text language sql as $$select current_setting('test.auth_role')$$")
        run("select set_config('test.auth_role','authenticated',true)")
        run("create function zella_has_role(uuid,text[]) returns boolean language sql as $$select current_setting('test.member_role')=any($2)$$")
        run("create function zella_digits(text) returns text language sql immutable as $$select $1$$")
        run('create table businesses(id uuid primary key); create table customers(id uuid primary key,business_id uuid,phone text,email text,created_at timestamptz,updated_at timestamptz,do_not_sms boolean,do_not_email boolean,do_not_call boolean)')
        run(re.search(r'create table if not exists public.contact_consents \(.*?\n\);',source('zella_automation_foundation'),re.S)[0])
        run(function('zella_automation_foundation','zella_record_consent'))
        run('insert into businesses values(auth.uid()); insert into customers(id,business_id,do_not_sms,do_not_email,do_not_call) values(auth.uid(),auth.uid(),true,true,true)')
        run("select set_config('test.member_role','staff',true)")
        rejects("select zella_record_consent(auth.uid(),'sms','opted_in','staff',auth.uid())",'NOT_ALLOWED')
        rejects("select zella_record_consent(auth.uid(),'sms','opted_out','email_link',auth.uid())",'NOT_ALLOWED')
        run("select set_config('test.member_role','viewer',true)")
        rejects("select zella_record_consent(auth.uid(),'sms','opted_out','staff',auth.uid())",'NOT_ALLOWED')
        run("select set_config('test.member_role','manager',true)")
        run("select zella_record_consent(auth.uid(),'sms','opted_in','staff',auth.uid())")
        assert value('select do_not_sms from customers')
        run("select set_config('test.auth_role','service_role',true)")
        run("select zella_record_consent(auth.uid(),'sms','opted_in','inbound_sms_keyword',auth.uid())")
        assert not value('select do_not_sms from customers')
        print('PASS consent sources, viewer/manager permissions and service-only flag clearing')
    with db.transaction(force_rollback=True):
        run('create table staff_members(id uuid,business_id uuid); create table appointments(id uuid,business_id uuid,staff_id uuid)')
        run(function('zella_crm_details','zella_staff_business_guard'))
        run('create trigger staff_guard before insert or update on appointments for each row execute function zella_staff_business_guard()')
        run("insert into staff_members values('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000002')")
        rejects("insert into appointments values(gen_random_uuid(),gen_random_uuid(),'00000000-0000-0000-0000-000000000001')",'BAD_STAFF')
        run('insert into appointments select gen_random_uuid(),business_id,id from staff_members')
        assert not value("select prosecdef from pg_proc where oid='zella_staff_business_guard()'::regprocedure")
        print('PASS same-business staff guard runs with caller permissions')
    db.rollback()
