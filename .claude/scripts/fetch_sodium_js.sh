#!/usr/bin/env bash
# Download sodium.js (sumo) used by browser tests into packages/<pkg>/test/web/
# (default: every package with a test/web/template.html.tpl).
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$root/.claude/scripts/env.sh"
if [[ $# -eq 0 ]]; then
  for t in "$root"/packages/*/test/web/template.html.tpl; do
    [[ -e $t ]] || continue
    p="${t#"$root/packages/"}"
    set -- "$@" "${p%%/*}"
  done
fi
for p in "$@"; do
  cd "$root/packages/$p"
  dart run sodium:update_web --sumo --no-edit-index -d test/web
done
