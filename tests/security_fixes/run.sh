#!/usr/bin/env bash
# Every security fix suite (security audit 18 Nov 2026), each on its own isolated zsec_fix_* copy. Exits 1 on any failure.
HERE="$(cd "$(dirname "$0")" && pwd)"; rc=0
for t in "$HERE"/*.sh; do
  case "$(basename "$t")" in lib.sh|run.sh) continue;; esac
  echo "== $(basename "$t" .sh)"; "$t" || rc=1
done
exit $rc
