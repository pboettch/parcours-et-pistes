#!/usr/bin/env bash
# Download sodium.js (sumo) used by browser tests into packages/<pkg>/test/web/
# (default: every package with a test/web/template.html.tpl).
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$root/.claude/scripts/env.sh"
for p in "${@:-pep_channel pep_core}"; do
  cd "$root/packages/$p"
  dart run sodium:update_web --sumo --no-edit-index -d test/web
done
