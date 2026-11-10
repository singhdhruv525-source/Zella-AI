"""Validate the outer transaction of a complete rollback, ignoring SQL literals."""
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
sql = path.read_text()
# Tokenize quoted bodies before looking for transaction statements. Block comments may nest.
parts = []
i = 0
while i < len(sql):
    if sql.startswith('--', i):
        end = sql.find('\n', i)
        i = len(sql) if end < 0 else end + 1
        parts.append(' ')
    elif sql.startswith('/*', i):
        depth = 1
        i += 2
        while depth and i < len(sql):
            if sql.startswith('/*', i): depth += 1; i += 2
            elif sql.startswith('*/', i): depth -= 1; i += 2
            else: i += 1
        if depth: sys.exit('refused: unterminated comment')
        parts.append(' ')
    elif sql[i] in "'\"":
        quote = sql[i]
        escaped = (quote == "'" and i > 0 and sql[i-1] in 'eE'
                   and (i < 2 or not (sql[i-2].isalnum() or sql[i-2] == '_')))
        i += 1
        while i < len(sql):
            if sql[i] == quote:
                i += 1
                if i < len(sql) and sql[i] == quote: i += 1; continue
                break
            if escaped and sql[i] == '\\': i += 1
            i += 1
        else: sys.exit('refused: unterminated quote')
        parts.append(' literal ')
    elif (m := re.match(r'\$(?:[A-Za-z_][A-Za-z_0-9]*)?\$', sql[i:])):
        tag = m.group()
        end = sql.find(tag, i + len(tag))
        if end < 0: sys.exit('refused: unterminated dollar quote')
        i = end + len(tag)
        parts.append(' body ')
    else:
        parts.append(sql[i]); i += 1
clean = ''.join(parts)
statements = [s.strip().lower() for s in clean.split(';') if s.strip()]
if (not path.name.endswith('_rollback.sql') or len(statements) < 2
        or statements[0] != 'begin' or statements[-1] != 'commit'
        or not clean.rstrip().endswith(';') or '\\' in clean
        or any(re.match(r'^(begin|start\s+transaction|commit|end|rollback|abort)\b', s)
               for s in statements[1:-1])):
    sys.exit('refused: expected a complete *_rollback.sql with one outer BEGIN; ... COMMIT; transaction')
