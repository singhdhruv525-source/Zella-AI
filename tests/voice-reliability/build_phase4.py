# Phase 4 staging layer: the live bodies of the call-trigger, callback, knowledge and assistant-config functions
# (phase4_md5.txt, matched against the repo like build_functions.py), the live base prompt (zella_brain.sql's
# zella_brain_prompt, renamed in production to zella_brain_prompt_base), and production's triggers on calls and callbacks.
# Run: python3 -I build_phase4.py <sql dir> <out>
import re, sys, subprocess, hashlib
sqldir, out = sys.argv[1], sys.argv[2]
subprocess.run([sys.executable, '-I', 'build_functions.py', 'phase4_md5.txt', sqldir, out + '.fns'], check=True, stdout=subprocess.DEVNULL)
s = open(sqldir + '/zella_brain.sql').read()
m = re.search(r'create or replace function public\.zella_brain_prompt\(p_business_id uuid\) returns text.*?\nend \$\$;', s, re.S)
base = m.group(0).replace('public.zella_brain_prompt(', 'public.zella_brain_prompt_base(', 1)
body = base[base.index('as $$') + 5: base.rindex('$$')]
assert hashlib.md5(body.encode()).hexdigest() == 'cff34c20956b1fcdab5dd8ff8afd4bdc', 'base prompt differs from production'
fns = open(out + '.fns').read()
triggers = """
drop trigger if exists zella_call_insight_queue on public.calls;
create trigger zella_call_insight_queue after insert or update of transcript, ended_at on public.calls for each row execute function public.zella_call_insight_queue_trg();
drop trigger if exists zella_call_integrity on public.calls;
create trigger zella_call_integrity before insert or update on public.calls for each row execute function public.zella_call_integrity_trg();
drop trigger if exists zella_calls_callbacks_trg on public.calls;
create trigger zella_calls_callbacks_trg after insert or update on public.calls for each row execute function public.zella_calls_to_callbacks();
drop trigger if exists zella_auto_assign_callback_trg on public.callbacks;
create trigger zella_auto_assign_callback_trg before insert on public.callbacks for each row execute function public.zella_auto_assign_callback();
"""
# the wrapper calls the base, so the base goes first
open(out, 'w').write('set check_function_bodies = off;\n' + open('phase4_tables.sql').read() + '\n-- zella_brain_prompt_base (live body = zella_brain.sql zella_brain_prompt, renamed)\n' + base + '\n\n' + fns + triggers)
print('phase 4 layer written')
