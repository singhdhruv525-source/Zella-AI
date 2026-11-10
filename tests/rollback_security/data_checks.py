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
# A replacement ID shares the backed-up business/key; records must keep resolving to it.
run('''
alter table crm_record_types add unique (business_id,key);
insert into backup_20261104_types select gen_random_uuid(), business_id, 'collision', singular, plural, icon, title_label, link_person, statuses, closed_statuses, fields, columns, notice, enabled, position, preset_key, created_at, updated_at from backup_20261104_types limit 1;
insert into crm_record_types(business_id,key,singular,plural,statuses) values ('00000000-0000-0000-0000-000000000001','collision','Replacement','Replacements','[]');
update crm_records set type_key='collision';
'''+part[part.index('-- 3.'):part.index('-- 4. capability')]+'''
do $$ begin
 assert (select count(*)=2 from crm_record_types);
 assert (select count(*)=2 from crm_records r join crm_record_types t on t.business_id=r.business_id and t.key=r.type_key);
 assert (select t.id <> b.id and t.singular=b.singular from crm_record_types t join backup_20261104_types b using(business_id,key) where t.key='collision');
end $$;''')
run('''create table industry_automation_presets(industry_key text,name text,trigger_type text,trigger_config jsonb);
create table automations(id int,name text,trigger_type text,trigger_config jsonb,created_by uuid);
create table industry_automation_runs(automation_id int);
insert into industry_automation_presets values ('legal','Deadline tomorrow','deadline','{"days":1}');
insert into automations values (1,'Deadline tomorrow','deadline','{"days":1}',null),(2,'Deadline tomorrow','custom','{}',null),(3,'Deadline tomorrow','deadline','{"days":2}',null),(4,'Deadline tomorrow','deadline','{"days":1}',null),
  (5,'Deadline tomorrow','deadline','{"days":1}','00000000-0000-0000-0000-000000000005');  -- an owner's look-alike rule: kept
insert into industry_automation_runs values(4);
'''+part[part.index('with v(industry_key'):part.index('-- 7. photos')]+'''
do $$ begin assert (select array_agg(id order by id)=array[2,3,4,5] from automations); assert not exists(select from industry_automation_presets); end $$;''')
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
run("create table ai_tool_calls(lookup_ref text); insert into ai_tool_calls values('order-123');"+block+block+
    "alter table ai_tool_calls add lookup_ref text; update ai_tool_calls set lookup_ref='order-456';"+block+block+'''
do $$ declare archived text; original text; begin
 assert (select lookup_ref_rolled_back='order-456' from ai_tool_calls);
 select attname into strict archived from pg_attribute where attrelid='ai_tool_calls'::regclass and attname like 'lookup_ref_rb_%' and not attisdropped;
 execute format('select %I from ai_tool_calls', archived) into original;
 assert original='order-123';
end $$;''')
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

# Archive only non-null table data, including false/zero values, across repeated rollback.
r=(ROOT/'sql/rollback/zella_tables_rollback.sql').read_text()
start=r.rindex('do $$',0,r.index('create table if not exists public.table_data_rolled_back'))
archive=r[start:r.index('end $$;',start)+7]
run('''create table business_capabilities(business_id uuid, capability text);
create table appointments(business_id uuid, table_ids uuid[]);
create table waitlist_entries(business_id uuid, party_size int, preferences text[], contact_ok boolean);
create table table_states(business_id uuid);
insert into appointments values(null,null),(null,'{}');
insert into waitlist_entries values(null,null,null,null),(null,0,null,null),(null,null,'{}',null),(null,null,null,false);
insert into business_capabilities values(null,'tables'),(null,'other');
'''+archive+'''do $$ begin
 assert (select count(*)=1 from table_data_rolled_back where source_table='appointments');
 assert (select count(*)=3 from table_data_rolled_back where source_table='waitlist_entries');
 assert (select count(*)=1 from table_data_rolled_back where source_table='business_capabilities');
end $$;''')
print('PASS non-null table data archive filters')
