# The live zella_ai_voice = zella_voice_rules.sql body with comments stripped + the caller patch from zella_inbound_calls.sql.
# Writes it only if the result has exactly the live md5 (prod_md5.txt). Run: python3 -I rebuild_ai_voice.py <sql dir> <prod_md5> <out>
import re, hashlib, sys
prod = dict(x.split('=') for x in open(sys.argv[2]).read().split())
s = open(sys.argv[1] + '/zella_voice_rules.sql').read()
m = re.search(r'create\s+or\s+replace\s+function\s+public\.zella_ai_voice\s*\(', s)
am = re.compile(r'\bas\s+(\$[a-z_0-9]*\$)', re.I).search(s, m.end()); tag = am.group(1); b0 = am.end(); b1 = s.find(tag, b0)
body = s[b0:b1]; end = s.find(';', b1 + len(tag)); head, tail = s[m.start():b0], s[b1:end + 1]
def strip(body):
    out = []
    for line in body.split('\n'):
        if re.match(r'^\s*--', line): continue
        q = False; cut = None
        for i, ch in enumerate(line):
            if ch == "'": q = not q
            if not q and line[i:i+2] == '--': cut = i; break
        if cut is not None: line = line[:cut].rstrip()
        out.append(line)
    return '\n'.join(out)
anchor = "'emergency_keywords', to_jsonb(v_keywords),"
p = strip(body).replace(anchor, anchor + "\n      'caller', public.zella_caller_context(v_biz, coalesce(nullif(v_args ->> 'caller_number', ''), v_call.from_number)),", 1)
if hashlib.md5(p.encode()).hexdigest() != prod['zella_ai_voice']: sys.exit('zella_ai_voice does not reproduce the live body')
open(sys.argv[3], 'w').write(head + p + tail + '\n')
