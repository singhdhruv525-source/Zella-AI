#!/usr/bin/env bash
# The security fix suites of claude/security-fixes-g (H3, H4, H5), each on its own isolated zsec_fix_* copy.
HERE="$(cd "$(dirname "$0")" && pwd)"; rc=0
for t in "$HERE"/*.sh; do
  case "$(basename "$t")" in lib.sh|run.sh) continue;; esac
  echo "== $(basename "$t" .sh)"; "$t" || rc=1
done
exit $rc
