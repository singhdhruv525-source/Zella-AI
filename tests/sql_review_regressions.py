"""Focused SQL regressions. Run against a disposable PostgreSQL database with
ZELLA_TEST_DSN='dbname=zella_review' python tests/sql_review_regressions.py.
Requires psycopg and pglast; fixtures are synthetic and rolled back.
"""
import os
from pathlib import Path
import re
import psycopg
from pglast import parse_sql

SQL = Path(__file__).resolve().parents[1] / 'sql'

def source(name):
    return (SQL / name).read_text()

def function(name, file):
    text = source(file)
    start = text.index('create or replace function public.' + name + '(')
    return text[start:text.index('$$;', start) + 3]

with psycopg.connect(os.environ['ZELLA_TEST_DSN']) as db:
    def run(sql, params=None):
        return db.execute(sql, params)
    def value(sql, params=None):
        return run(sql, params).fetchone()[0]
    def rejects(sql):
        try:
            with db.transaction():
                run(sql)
        except psycopg.Error as e:
            assert 'NOT_ALLOWED' in str(e), str(e)
        else:
            raise AssertionError('Expected NOT_ALLOWED')

    # Parse every migration: catches syntax errors without requiring absent Supabase schema.
    for file in SQL.rglob('*.sql'):
        parse_sql(file.read_text())
    print('PASS: SQL syntax')
    run("create schema auth; create function auth.uid() returns uuid language sql as $$ select nullif(current_setting('test.uid', true), '')::uuid $$")
    uid = '00000000-0000-0000-0000-000000000001'
    run("select set_config('test.uid', %s, false)", (uid,))
    run("create table businesses(id uuid primary key, cancelled_at timestamptz, timezone text); create table business_members(business_id uuid, user_id uuid, status text, role text)")
    run("insert into businesses values (%s,null,'UTC'); insert into business_members values (%s,%s,'active','owner')".replace('%s', "'"+uid+"'"))
    run("create function zella_has_role(uuid,text[]) returns boolean language sql as $$ select exists(select 1 from business_members where business_id=$1 and user_id=auth.uid() and status='active' and role=any($2)) $$")
    run("create function zella_mfa_satisfied() returns boolean language sql as $$ select current_setting('test.mfa',true)='true' $$")
    run("create function zella_knowledge_gap_editor(uuid) returns boolean language sql as $$select false$$")
    run("create table knowledge_gaps(id uuid, business_id uuid, status text, question text, knowledge_item_id uuid, resolved_by uuid, resolved_at timestamptz)")
    # Use the real base knowledge table, then its schema extension.
    base=source('zella_knowledge.sql'); start=base.index('create table if not exists public.knowledge_items'); end=base.index('create index', start)
    run(base[start:end])
    rollback=source('rollback/zella_knowledge_learning_rollback.sql')
    run(rollback[rollback.index('create or replace'):rollback.rindex('commit;')])
    run("insert into knowledge_gaps values (%s,%s,'open','Question',null,null,null)",(uid,uid))
    for role,mfa in [('viewer','true'),('owner','false')]:
        run('update business_members set role=%s',(role,));run("select set_config('test.mfa',%s,false)",(mfa,))
        rejects(f"select zella_answer_knowledge_gap('{uid}','Answer')")
        rejects(f"select zella_dismiss_knowledge_gap('{uid}')")
    run("update business_members set role='owner'; select set_config('test.mfa','true',false)")
    assert value(f"select zella_answer_knowledge_gap('{uid}','Answer')")
    assert value('select count(*) from knowledge_items where approved_by=auth.uid()') == 1
    assert value("select to_regprocedure('zella_knowledge_gap_editor(uuid)')") is None
    print('PASS: rollback preserves editor and MFA checks; base knowledge has source_url')

    # Whole hour, fractional hour, and sub-minute start positions round up.
    expression=re.search(r"date_trunc\('hour', greatest.*?\* v_step\)",source('zella_followups.sql'))[0]
    expression=expression.replace('greatest(p_from, now())',"'2026-01-01 10:30:01+00'::timestamptz")
    for step,expected in [('60 minutes','11:00:00'),('90 minutes','11:30:00'),('15 minutes','10:45:00')]:
        assert value('select ('+expression.replace('v_step',f"interval '{step}'")+")::time::text") == expected
    condition=re.search(r"if (v_text ~ .*?) then raise exception 'NO_MARKETING",source('zella_industry_engine.sql'))[1]
    for text,expected in [('20% off this week',True),('off',False),('office',False),('a discount today',True)]:
        assert value('select '+condition.replace('%','%%').replace('v_text','%s'),(text,)*condition.count('v_text')) is expected
    print('PASS: slot alignment and marketing filter')

    # Apply each string replacement to the real repository reminder variants.
    patch=source('zella_channel_review.sql'); patch=patch[patch.index('  -- the sender:'):patch.index('end $$;',patch.index('  -- the sender:'))]
    replacements=re.findall(r'replace\(def, \$a\$(.*?)\$a\$,\s*\$a\$(.*?)\$a\$\)',patch,re.S)
    for file in ['zella_email_sender.sql','zella_followup_emails.sql']:
        definition=function('zella_claim_reminders',file)
        for old,new in replacements:
            definition=definition.replace(old,new)
        assert 'channel_needs_review' in definition and 'automation_disabled' in definition
        parse_sql(definition)
    print('PASS: both reminder definition variants')

    # Industry backfill: same-name foreign rules and owner keys remain untouched.
    run('create table industry_automation_presets(industry_key text,name text,trigger_type text,trigger_config jsonb); create table zella_prior_industry_presets (like industry_automation_presets); create table automations(business_id uuid,name text,trigger_type text,trigger_config jsonb,updated_at timestamptz)')
    run("create function zella_industry_key_for(uuid) returns text language sql as $$select case when $1=auth.uid() then 'childcare' else 'other' end$$")
    old='{"type_key":"enrollments","rule":{"message":"hello"},"before_hours":24}'
    run("insert into zella_prior_industry_presets values ('childcare','Start date reminder','record_due_reminder',%s)",(old,))
    run("insert into industry_automation_presets select industry_key,name,trigger_type,trigger_config || '{\"due_field\":\"start_date\",\"include_closed\":true}' from zella_prior_industry_presets")
    for biz in [uid,'00000000-0000-0000-0000-000000000002']:
        run("insert into automations select %s,name,trigger_type,trigger_config || '{\"notify_via\":\"email\",\"custom\":42}',null from zella_prior_industry_presets",(biz,))
    statement=source('zella_industry_fixes.sql').split('update public.automations a\n')[-1].split('commit;')[0]
    run('update public.automations a\n'+statement)
    assert value("select trigger_config->>'due_field' from automations where business_id=auth.uid()")=='start_date'
    assert value("select trigger_config->>'custom' from automations where business_id=auth.uid()")=='42'
    assert value("select trigger_config->>'due_field' from automations where business_id<>auth.uid()") is None
    print('PASS: industry-scoped backfill preserves owner configuration')
    # Apply the booking patch twice to the real staff-anchor definition and an hours variant.
    booking=source('zella_booking_buffers.sql')
    block=booking[booking.index('do $$'):booking.index('end $$;')+7]
    run("create function zella_booking_buffer(uuid) returns int language sql as $$select 15$$")
    for hours in [False,True]:
        definition=function('zella_available_slots','zella_followups.sql')
        if hours:
            definition=definition.replace('  v_has_staff boolean;', '  v_has_staff boolean;\n  v_has_hours boolean;')
        run(definition)
        run(block);run(block)
        patched=value("select pg_get_functiondef('zella_available_slots(uuid,timestamptz,timestamptz,integer,uuid,integer,integer,uuid)'::regprocedure)")
        assert patched.count('v_buffer interval')==1 and 'a.end_time + v_buffer > r.t' in patched
    print('PASS: both booking declaration anchors and rerun')

    # Real patch block must fail closed if any timer anchor has drifted.
    engine=source('zella_industry_fixes.sql')
    block=engine[engine.index('do $do$'):engine.index('end $do$;')+9]
    for missing in [None, 'r.assigned_to, r.due_at from public.crm_records r', 'and r.due_at - make_interval']:
        with db.transaction(force_rollback=True):
            run(function('zella_industry_status_trg','zella_industry_engine.sql'))
            definition=function('zella_run_industry_timers','zella_industry_engine.sql')
            if missing:
                definition=definition.replace(missing,missing.replace('r.', 'r .'))
            run(definition)
            if missing:
                try:
                    with db.transaction(): run(block)
                except psycopg.Error as e:
                    assert 'anchor missing' in str(e)
                else: raise AssertionError('Drift must fail closed')
            else: run(block);run(block)
    print('PASS: industry patch guards and rerun')

    # Preserve the hardened invitation behavior, including legacy seats without an invitation.
    run('create table auth.users(id uuid,email text); create table business_invitations(business_id uuid,auth_user_id uuid,role text,status text,expires_at timestamptz,email text,accepted_at timestamptz,updated_at timestamptz); create table audit_logs(user_id uuid,action text,business_id uuid,entity_type text,new_data jsonb)')
    run("create function zella_session_proved_email() returns boolean language sql as $$select current_setting('test.proved',true)='true'$$")
    run("insert into auth.users values (%s,'test@example.invalid')",(uid,))
    run(function('zella_accept_my_invitations','zella_business_app.sql'))
    run("update business_members set status='invited'; select set_config('test.proved','false',false)")
    assert value('select zella_accept_my_invitations()')==0
    run("select set_config('test.proved','true',false)")
    run("insert into business_invitations values (%s,%s,'owner','sent',now()-interval '1 day','test@example.invalid',null,null)",(uid,uid))
    assert value('select zella_accept_my_invitations()')==0
    run('delete from business_invitations')
    assert value('select zella_accept_my_invitations()')==1
    print('PASS: expired invitations and email proof for legacy seats')

    # Restore only routing keys, including absent keys and JSON null, preserving current extras.
    restore=source('zella_config_migration.sql')
    statement=restore[restore.index('    update ai_agent_configs\n'):restore.index('  end if;',restore.index('    update ai_agent_configs\n'))]
    run('create table ai_agent_configs(agent_id uuid,escalation_rules jsonb,updated_at timestamptz)')
    run("insert into ai_agent_configs values (%s, '{\"transfer_number\":\"new\",\"transfer_number_source\":\"setup\",\"owner_edit\":true}',null)",(uid,))
    run("do $$ declare s record; v_agent uuid := auth.uid(); begin select '{\"transfer_number\":null}'::jsonb as escalation_rules into s;"+statement+' end $$;')
    assert value('select escalation_rules from ai_agent_configs')=={'transfer_number':None,'owner_edit':True}
    print('PASS: routing restore preserves unrelated edits and key absence')
    # Run the customer assignment itself against blank and populated emails.
    expression=re.search(r"email = (case .*? end),", source('zella_brain.sql'))[1]
    for stored,expected in [(None,'new@example.invalid'),('  ','new@example.invalid'),('owner@example.invalid','owner@example.invalid')]:
        assert value('select '+expression+' from (select %s::text as email,%s::text as v_email) x',(stored,'new@example.invalid'))==expected
    run("create function zella_can_read_call_content(uuid) returns boolean language sql as $$select false$$")
    run(function('zella_call_insights_list','zella_call_intelligence.sql'))
    rejects(f"select zella_call_insights_list('{uid}')")
    print('PASS: existing customer email retained; call-content RPC denies unauthorized readers')

    # Evaluate every write-policy predicate for active viewers, editors and inactive editors.
    policies=re.findall(r'create policy (?:staff_members|blocked_times)_member_(?:insert|update|delete).*?;',source('zella_crm_details.sql'),re.S)
    assert len(policies)==6
    for policy in policies:
        table='staff_members' if 'staff_members_member' in policy else 'blocked_times'
        predicates=re.findall(r'(?:using|with check) \((exists .*?)\)(?=\s*(?:with check|;))',policy,re.S)
        assert predicates
        for predicate in predicates:
            for role,status,allowed in [('viewer','active',False),('owner','active',True),('owner','invited',False)]:
                run('update business_members set role=%s,status=%s',(role,status))
                assert value('select '+predicate+f' from (select auth.uid() as business_id) {table}') is allowed
    print('PASS: all six staff and blocked-time write policies enforce active editing membership')
    db.rollback()

# Independent sessions exercise the actual insert trigger under contention.
with psycopg.connect(os.environ['ZELLA_TEST_DSN'], autocommit=True) as setup:
    setup.execute('create table n8n_dispatch_state(workflow text primary key,last_triggered_at timestamptz); create table kick_test(id int,due_at timestamptz); create table dispatch_calls(id int)')
    setup.execute("create function zella_dispatch_n8n() returns void language sql as $$insert into dispatch_calls values(1)$$")
    setup.execute(function('zella_kick_dispatch','zella_dispatcher.sql'))
    setup.execute('create trigger kick after insert on kick_test for each row execute function zella_kick_dispatch()')
    try:
        with psycopg.connect(os.environ['ZELLA_TEST_DSN']) as first, psycopg.connect(os.environ['ZELLA_TEST_DSN']) as second:
            first.execute('insert into kick_test values (1,now())')
            second.execute("set local statement_timeout='500ms'; insert into kick_test values (2,now())")
            assert second.execute('select count(*) from dispatch_calls').fetchone()[0]==0
            first.commit()
            second.execute('insert into kick_test values (3,now())')
            assert second.execute('select count(*) from dispatch_calls').fetchone()[0]==1
        print('PASS: contended dispatch inserts return immediately; debounce preserved')
    finally:
        setup.execute('drop table kick_test; drop function zella_kick_dispatch(); drop function zella_dispatch_n8n(); drop table dispatch_calls; drop table n8n_dispatch_state')

print('All focused SQL checks passed')
