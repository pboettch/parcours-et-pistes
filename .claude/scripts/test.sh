#!/usr/bin/env bash
# Run pep_core tests on the Dart VM and in Chromium. Pass extra args to `dart test`.
# Integration tests (tag "broker") need the dev broker: .claude/scripts/broker.sh start
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$root/.claude/scripts/env.sh"
export CHROME_EXECUTABLE="${CHROME_EXECUTABLE:-/usr/bin/chromium}"
cd "$root/packages/pep_core"
[[ -f test/web/sodium.js ]] || "$root/.claude/scripts/fetch_sodium_js.sh"
dart test -p vm,chrome "$@"
