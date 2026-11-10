-- Run on a restored isolated baseline. All fixtures are synthetic and rolled back.
begin;
set local session_replication_role = replica;
insert into public.businesses (id,name,industry_id) values
 ('10000000-0000-0000-0000-000000000001','Privacy A','20000000-0000-0000-0000-000000000001'),
 ('10000000-0000-0000-0000-000000000002','Privacy B','20000000-0000-0000-0000-000000000001');
insert into public.industry_modules(id,industry_id,name,slug) values
 ('30000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','Calls','calls');
insert into public.business_modules(business_id,module_id) select id,'30000000-0000-0000-0000-000000000001' from businesses where name like 'Privacy %';
insert into public.business_members(business_id,user_id,role) values
 ('10000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001','owner');
insert into public.calls(id,business_id,direction,recording_url,transcript) values
 ('50000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','inbound','private-url','private-text'),
 ('50000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000002','inbound','other-url','other-text');
do $$ declare token text; begin
 select inbound_email_token into token from businesses where name='Privacy A';
 assert length(token)=32;
 assert substring(token || '@example.test' from '(?:^|[<[:space:]])([a-z0-9]{12}|[a-f0-9]{32})@')=token;
 assert substring('Name <abcdef123456@example.test>' from '(?:^|[<[:space:]])([a-z0-9]{12}|[a-f0-9]{32})@')='abcdef123456';
 assert substring('xabcdef123456@example.test' from '(?:^|[<[:space:]])([a-z0-9]{12}|[a-f0-9]{32})@') is null;
 assert not has_column_privilege('authenticated','public.calls','transcript','select');
 assert not has_column_privilege('authenticated','public.calls','recording_url','select');
 assert has_column_privilege('authenticated','public.calls','id','select');
end $$;
set local request.jwt.claims = '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}';
set local role authenticated;
do $$ begin
 assert (select count(*)=1 from public.calls_view);
 assert (select transcript='private-text' from public.calls_view);
 assert not exists (select * from public.zella_call_content('50000000-0000-0000-0000-000000000002'));
 begin perform transcript from public.calls; raise exception 'sensitive SELECT allowed'; exception when insufficient_privilege then null; end;
end $$;
reset role;
create function public.zella_mfa_satisfied() returns boolean language sql as 'select false';
set local role authenticated;
do $$ begin
 assert not exists(select * from public.zella_call_content('50000000-0000-0000-0000-000000000001'));
end $$;
reset role;
drop function public.zella_mfa_satisfied();
update public.business_members set role='staff' where user_id='40000000-0000-0000-0000-000000000001';
set local role authenticated;
do $$ begin
 assert (select count(*)=1 from public.calls_view);
 assert (select transcript is null and recording_url is null from public.calls_view);
 assert not exists (select * from public.zella_call_content('50000000-0000-0000-0000-000000000001'));
end $$;
reset role;
update public.business_members set role='owner' where user_id='40000000-0000-0000-0000-000000000001';
update public.business_modules set enabled=false;
set local role authenticated;
do $$ begin
 assert not exists(select * from public.calls_view);
 assert not exists(select * from public.zella_call_content('50000000-0000-0000-0000-000000000001'));
end $$;
reset role;
set local request.jwt.claims='{"role":"service_role"}';
set local role service_role;
do $$ begin assert (select count(*)=2 from public.calls_view where transcript is not null); end $$;
rollback;
