"""Static migration checks; requires pglast (tested with 8.7)."""
from pathlib import Path
import re
import pglast

SQL = Path(__file__).resolve().parents[1] / 'sql'
FILES = ['zella_admin_alerts', 'zella_admin_ops', 'zella_after_hours_reply',
         'zella_automation_completion', 'zella_dispatcher', 'zella_inbound_replies',
         'zella_industry_engine', 'zella_industry_presets_more', 'zella_industry_rule_list',
         'zella_industry_templates', 'zella_invitation_hardening', 'zella_knowledge',
         'zella_knowledge_extras', 'zella_knowledge_learning', 'zella_lead_capture']
for name in FILES:
    pglast.parse_sql((SQL / (name + '.sql')).read_text())
ops = (SQL / 'zella_admin_ops.sql').read_text()
for name in ['numbers', 'calls', 'messages', 'automations', 'runs']:
    body = re.search(r'create or replace function public.zella_admin_' + name + r'\(.*?\$\$;', ops, re.S)[0]
    pages = re.findall(r'order by ([^\n]*?) limit v_lim', body)
    assert pages and all(order.endswith(', id') for order in pages), (name, pages)
for line in (SQL / 'zella_industry_templates.sql').read_text().splitlines():
    if "('dental'" in line:
        assert '{{appointment}}' not in line
        assert all(key in line for key in ['{{business}}', '{{date}}', '{{time}}'])
lead = (SQL / 'zella_lead_capture.sql').read_text()
assert 'priority =' not in re.search(r'update public.customers set.*?;', lead, re.S)[0]
assert "'product','price'" in (SQL / 'zella_knowledge_learning.sql').read_text()
assert 'add column if not exists conflicts_with uuid' in (SQL / 'zella_knowledge_extras.sql').read_text()
print('PASS: 15 migrations parse; pagination, dental, priority and knowledge checks pass')
