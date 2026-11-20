-- Every way the existing callers raise an alert (positional 2 to 7 arguments, named arguments as the n8n event router
-- sends them, nulls, every severity, repeats of the same alert), plus three real callers. Run on a database with
-- production's zella_platform_alert and on one with sql/zella_alert_rules.sql and no rules: the rows must be the same.
delete from public.platform_alerts;
select public.zella_platform_alert('t_two', 'Two arguments');
select public.zella_platform_alert('t_three', 'Three', 'detail three');
select public.zella_platform_alert('t_four', 'Four', 'detail four', 'urgent');
select public.zella_platform_alert('t_five', 'Five', null, 'info', (select id from public.businesses order by id limit 1));
select public.zella_platform_alert('t_six', 'Six', repeat('x', 1500), 'bogus', null, 'six');
select public.zella_platform_alert('t_seven', 'Seven', 'd', null, null, null, null);
select public.zella_platform_alert('t_seven', 'Seven again', 'd2', 'warning', null, '', '{"a": 1}'::jsonb);
select public.zella_platform_alert('t_seven', 'Seven third', null, 'warning', null, '', '{"b": 2}'::jsonb);
select public.zella_platform_alert(p_kind => 'integration_disconnected', p_title => 'Meta disconnected', p_detail => null, p_severity => 'urgent',
  p_business_id => (select id from public.businesses order by id limit 1), p_dedupe_key => 'meta', p_meta => '{"event_id": "e1"}'::jsonb);
select public.zella_platform_alert(p_kind => 't_named_short', p_title => 'Named, two only');
select public.zella_record_provider_check('vapi', false, 'timeout one');
select public.zella_record_provider_check('vapi', false, 'timeout two');
select public.zella_record_provider_check('vapi', true, null);
select public.zella_report_service_health('voice', false, 'Calls are slow', true);
