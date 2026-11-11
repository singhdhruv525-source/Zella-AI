from pathlib import Path
import subprocess
import tempfile
ROOT=Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory() as tmp:
    p=Path(tmp)/'case_rollback.sql'
    for sql, valid in [
        ('begin; select 1; commit;',True),
        ('-- header\nbegin; do $$ begin perform 1; end $$; commit;',True),
        (r"begin; select E'escaped\'quote; commit;'; commit;",True),
        ('begin; /* outer /* commit; */ still comment */ select 1; commit;',True),
        ("begin; do $body$ begin perform '$$ commit;'; end $body$; commit;",True),
        ('begin; /* unterminated /* nested */ commit;',False),
        ('select 1;',False), ('-- begin;\nselect 1; -- commit;',False),
        ('begin; select 1;',False), ('begin; commit; select 1; commit;',False),
        ('begin; select 1; commit; select 2;',False),
        ('begin; \\set ON_ERROR_STOP off\ncommit;',False),
        ("begin; select '\\'; commit; begin; commit;",False),
    ]:
        p.write_text(sql)
        result=subprocess.run(['python3',str(ROOT/'sql/rollback/validate.py'),str(p)],capture_output=True)
        assert (result.returncode==0)==valid,(sql,result.stderr)
    for path in (ROOT/'sql/rollback').glob('*.sql'):
        result=subprocess.run(['python3',str(ROOT/'sql/rollback/validate.py'),str(path)],capture_output=True)
        assert (result.returncode==0)==path.name.endswith('_rollback.sql'),path
print('PASS outer transactions, fragments, nested bodies, misleading comments and early commits')
