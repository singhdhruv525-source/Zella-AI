"""Exercise rollback data boundaries with isolated synthetic tables, never production."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
P = ['psql','-X','-h','/var/lib/postgresql/zella-sec','-p','55433','-U','postgres','-v','ON_ERROR_STOP=1']
subprocess.run(['bash','-c','source "$1"; zella_require_isolated /var/lib/postgresql/zella-sec 55433 zrbdata','_',str(ROOT/'tests/lib/isolated_guard.sh')],check=True)
subprocess.run(P+['-d','postgres','-c','drop database if exists zrbdata','-c','create database zrbdata'],check=True,capture_output=True)
def run(sql):
    r=subprocess.run(P+['-d','zrbdata'],input=sql,text=True,capture_output=True)
    if r.returncode: raise AssertionError(r.stderr)
part=(ROOT/'sql/rollback/industry_data_part.sql').read_text()
run('''create table crm_records(id int, business_id int, data jsonb);
create table crm_record_secrets(record_id int,business_id int,field_key text,value text);
insert into crm_records values (1,1,'{"existing":42}'),(2,1,'[]');
insert into crm_record_secrets values (1,1,'new','secret'),(1,1,'existing','different'),(1,2,'foreign','secret'),(2,1,'array','secret'),(99,1,'orphan','secret');
'''+part[part.index('-- 1. private') if '-- 1. private' in part else part.index('-- 1. Copy'):part.index('-- 2. presets')]+'''
do $$ begin
 assert (select data='{"existing":42,"new":"secret"}'::jsonb from crm_records where id=1);
 assert (select data='[]'::jsonb from crm_records where id=2);
 assert (select count(*)=4 from crm_record_secrets);
end $$;''')
# Restore deleted presets and types with newly introduced NOT NULL defaults.
tables=(ROOT/'sql/baseline/01_tables.sql').read_text()
def ddl(name):
    start=tables.index('create table public.'+name+' (')
    return tables[start:tables.index('\n);',start)+4]
run(ddl('industry_crm_presets')+ddl('crm_record_types')+'''
alter table industry_crm_presets add primary key(key);
insert into industry_crm_presets(key,match,config) values ('deleted','{}','{}'),('existing','{}','{}');
create table backup_20261104_presets as table industry_crm_presets;
delete from industry_crm_presets where key='deleted';
insert into crm_record_types(business_id,key,singular,plural,statuses) values ('00000000-0000-0000-0000-000000000001','deleted','Thing','Things','[]');
create table backup_20261104_types as table crm_record_types;
alter table crm_record_types add fields_seen text[] not null default '{}';
delete from crm_record_types;
alter table crm_records add type_key text;
alter table crm_records alter business_id type uuid using '00000000-0000-0000-0000-000000000001'::uuid;
'''+part[part.index('-- 2. presets'):part.index('-- 4. capability')]+'''
do $$ begin
 assert (select count(*)=2 from industry_crm_presets);
 assert (select count(*)=1 from crm_record_types);
 assert (select fields_seen='{}' from crm_record_types);
end $$;''')
run('''create table industry_automation_presets(industry_key text,name text,trigger_type text,trigger_config jsonb);
create table automations(id int,name text,trigger_type text,trigger_config jsonb);
create table industry_automation_runs(automation_id int);
insert into industry_automation_presets values ('legal','Deadline tomorrow','deadline','{"days":1}');
insert into automations values (1,'Deadline tomorrow','deadline','{"days":1}'),(2,'Deadline tomorrow','custom','{}'),(3,'Deadline tomorrow','deadline','{"days":2}'),(4,'Deadline tomorrow','deadline','{"days":1}');
insert into industry_automation_runs values(4);
'''+part[part.index('with v(industry_key'):part.index('-- 7. photos')]+'''
do $$ begin assert (select array_agg(id order by id)=array[2,3,4] from automations); assert not exists(select from industry_automation_presets); end $$;''')
# Resource-only blocks are archived, others remain; repeat is a no-op.
sched=(ROOT/'sql/rollback/zella_scheduling_rollback.sql').read_text()
block=sched[sched.index('do $$'):sched.index('end $$;')+7]
run('''create table blocked_times(id int,resource_id int,staff_id int);
insert into blocked_times values(1,10,null),(2,10,20),(3,null,null);
'''+block+block+'''
do $$ begin
 assert (select array_agg(id order by id)=array[2,3] from blocked_times);
 assert (select array_agg(id)=array[1] from blocked_times_resources_rolled_back);
 assert not has_table_privilege('authenticated','blocked_times_resources_rolled_back','select');
end $$;''')
# Table rename loop survives rollback/redeploy/rollback and keeps both generations.
r=(ROOT/'sql/rollback/zella_report_schedules_rollback.sql').read_text();loop=r[r.index('do $$'):r.index('commit;')]
run('create table business_report_runs(id int); create index run_idx on business_report_runs(id); create table business_report_schedules(id int); insert into business_report_runs values(1);'+loop+loop+
    'create table business_report_runs(id int); create index run_idx on business_report_runs(id); create table business_report_schedules(id int); insert into business_report_runs values(2);'+loop+'''
do $$ begin
 assert (select id=2 from business_report_runs_rolled_back);
 assert (select count(*)=2 from pg_tables where tablename like 'business_report_runs_rb_%' or tablename='business_report_runs_rolled_back');
 assert not has_table_privilege('authenticated','business_report_runs_rolled_back','select');
end $$;''')
print('PASS private-value conflicts/tenant checks, backup reinsertion, automation matching, resource blocks, repeatable archives')
# Guarded reference rename is repeatable and preserves values.
r=(ROOT/'sql/rollback/zella_order_lookup_v2_rollback.sql').read_text();block=r[r.index('do $$'):r.index('end $$;')+7]
run("create table ai_tool_calls(lookup_ref text); insert into ai_tool_calls values('order-123');"+block+block+"do $$ begin assert (select lookup_ref_rolled_back='order-123' from ai_tool_calls); end $$;")
# Outlook archives must be private before accepting rows.
start=part.index('do $$ begin',part.index('-- 9. calendar'))
run('''create table calendar_connections(id int,provider text);
insert into calendar_connections values(1,'outlook'),(2,'google');
alter table blocked_times add connection_id int;
alter table blocked_times add end_time timestamptz;
'''+part[start:]+'''
do $$ begin
 assert (select id=2 from calendar_connections);
 assert (select id=1 from calendar_connections_outlook_rolled_back_20261104);
 assert (select relrowsecurity from pg_class where oid='calendar_connections_outlook_rolled_back_20261104'::regclass);
 assert not has_table_privilege('authenticated','calendar_connections_outlook_rolled_back_20261104','select');
 assert not has_table_privilege('anon','calendar_connections_outlook_rolled_back_20261104','select');
end $$;''')
print('PASS order references and private Outlook archive')
