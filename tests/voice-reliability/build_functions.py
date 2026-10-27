# Writes the staging copy of the live functions: each one's repo statement whose body md5 equals the live prosrc
# (raw, or with comments stripped). Order: helpers first. Run: python3 -I build_functions.py <prod_md5> <sql dir> <out>
import re, hashlib, glob, sys

prod = dict(x.split('=') for x in open(sys.argv[1]).read().split())
pat = re.compile(r'create\s+or\s+replace\s+function\s+public\.([a-z_0-9]+)\s*\(', re.I)
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
chosen = {}
for f in sorted(glob.glob(sys.argv[2] + '/*.sql')):
    s = open(f).read()
    for m in pat.finditer(s):
        name = m.group(1)
        if name not in prod: continue
        am = re.compile(r'\bas\s+(\$[a-z_0-9]*\$)', re.I).search(s, m.end())
        tag = am.group(1); b0 = am.end(); b1 = s.find(tag, b0); body = s[b0:b1]
        end = s.find(';', b1 + len(tag))
        head, tail = s[m.start():b0], s[b1:end + 1]
        for b in (body, strip(body)):
            if hashlib.md5(b.encode()).hexdigest() == prod[name]:
                chosen[name] = (f.split('/')[-1], head + b + tail)
order = ['zella_digits', 'zella_setting', 'zella_normalize_e164', 'zella_is_member', 'zella_has_role', 'zella_notify', 'zella_notify_owners', 'zella_next_call_time']
names = order + sorted(n for n in chosen if n not in order)
with open(sys.argv[3], 'w') as w:
    for n in names:
        if n in chosen: w.write('-- ' + n + ' (live body = ' + chosen[n][0] + ')\n' + chosen[n][1] + '\n\n')
print('written', len(chosen), 'missing', sorted(set(prod) - set(chosen)))
