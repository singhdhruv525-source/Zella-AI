# Generates sql/zella_review_sql_fixes.sql and its rollback from the live definitions on an ISOLATED copy
# (tests/review_sql/run.sh builds it). Never point it at production.
#   python3 sql/generators/review_sql_fixes/gen.py sql/generators/review_sql_fixes/spec.py sql/zella_review_sql_fixes.sql sql/rollback/zella_review_sql_fixes_rollback.sql zrevstate
"""Builds a version-guarded migration + exact rollback from live definitions in the isolated copy.
usage: gen.py <spec module> <out migration> <out rollback>
spec module defines: NAME, HEADER (str), FUNCS = [(regprocedure, [(old, new), ...]), ...], EXTRA_UP (sql), EXTRA_DOWN (sql),
ROLLBACK_HEADER (str)."""
import importlib.util, subprocess, sys

PSQL = ["psql", "-h", "/var/lib/postgresql/zella-sec", "-p", "55433", "-U", "postgres", "-qtAX", "-v", "ON_ERROR_STOP=1", "-d"]


def q(db, sql):
    return subprocess.run(PSQL + [db, "-c", sql], check=True, capture_output=True, text=True).stdout


def lit(s):
    return "'" + s.replace("'", "''") + "'"


spec_path, out_up, out_down = sys.argv[1:4]
db = sys.argv[4] if len(sys.argv) > 4 else "zrevstate"
sp = importlib.util.spec_from_file_location("spec", spec_path)
spec = importlib.util.module_from_spec(sp)
sp.loader.exec_module(spec)

guards, ups, downs = [], [], []
for sig, reps in spec.FUNCS:
    name = sig.replace('public.', '').split('(')[0]
    found = q(db, f"select oid::regprocedure from pg_proc where pronamespace = 'public'::regnamespace and proname = {lit(name)}").strip().split('\n')
    if len(found) != 1:
        sys.exit(f"{name}: expected exactly one function, found {found}")
    sig = found[0] if found[0].startswith('public.') else 'public.' + found[0]
    fdef = q(db, f"select pg_get_functiondef({lit(sig)}::regprocedure)").rstrip("\n")
    src = q(db, f"select prosrc from pg_proc where oid = {lit(sig)}::regprocedure")
    src = src[:-1] if src.endswith("\n") else src  # psql adds one newline
    new_def, new_src = fdef, src
    for rep in reps:
        old, new = rep[0], rep[1]
        header_only = len(rep) > 2 and rep[2] == "header"  # a change to the function's attributes, not its body
        for label, text in (("def", new_def),) + ((() if header_only else (("src", new_src),))):
            n = text.count(old)
            if n != 1:
                sys.exit(f"{sig}: expected 1 match in {label}, found {n}: {old[:80]!r}")
        new_def = new_def.replace(old, new)
        if not header_only:
            new_src = new_src.replace(old, new)
    old_md5 = q(db, f"select md5(pg_get_functiondef({lit(sig)}::regprocedure))").strip()
    new_md5 = q(db, f"begin; {new_def}; select md5(pg_get_functiondef({lit(sig)}::regprocedure)); rollback;").strip()
    guards.append((sig, old_md5, new_md5))
    num = getattr(spec, "ORDER", {}).get(sig.replace("public.", "").split("(")[0])
    ups.append((f"-- CodeRabbit #{int(num)}\n" if num is not None else "") + new_def + ";\n")
    downs.append(fdef + ";\n")


def guard_block(accept_label):
    lines = ["do $guard$", "declare v text;", "begin"]
    for sig, o, n in guards:
        lines.append(f"  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure({lit(sig)});")
        lines.append(f"  if v is null or v not in ('{o}', '{n}') then")
        lines.append(f"    raise exception 'VERSION_MISMATCH: {sig} is not the version this file was written against ({accept_label})';")
        lines.append("  end if;")
    lines += ["end $guard$;", ""]
    return "\n".join(lines)


with open(out_up, "w") as f:
    f.write(spec.HEADER.rstrip() + "\n\nbegin;\n\n")
    f.write("-- Version guard: every function below must be the version this file was written against (or already this\n"
            "-- file's version, so a second run is a no-op). Otherwise nothing changes.\n")
    f.write(guard_block("expected the live version or this file version"))
    f.write("\n".join(ups))
    f.write("\n" + spec.EXTRA_UP.strip() + "\n\ncommit;\n")

with open(out_down, "w") as f:
    f.write(spec.ROLLBACK_HEADER.rstrip() + "\n\nbegin;\n\n")
    f.write(guard_block("rollback"))
    f.write("\n" + spec.EXTRA_DOWN.strip() + "\n\n")
    f.write("\n".join(downs))
    f.write("\ncommit;\n")
print("wrote", out_up, out_down, len(guards), "functions")
