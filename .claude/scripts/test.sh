#!/usr/bin/env bash
# Run the tests of every package (or of the packages given with -P name) on the
# Dart VM and in Chromium. Other args go to `dart test` (e.g. -x broker).
# Broker integration tests (tag "broker") need: .claude/scripts/broker.sh start
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$root/.claude/scripts/env.sh"
export CHROME_EXECUTABLE="${CHROME_EXECUTABLE:-/usr/bin/chromium}"
packages=()
while [[ ${1:-} == -P ]]; do packages+=("$2"); shift 2; done
[[ ${#packages[@]} -gt 0 ]] || packages=(pep_content pep_channel pep_core)
status=0
for p in "${packages[@]}"; do
  echo "=== $p"
  cd "$root/packages/$p"
  if [[ -f test/web/template.html.tpl && ! -f test/web/sodium.js ]]; then
    "$root/.claude/scripts/fetch_sodium_js.sh" "$p"
  fi
  out="$(mktemp)"
  dart test -p vm,chrome "$@" > "$out" 2>&1 || status=1
  grep -E '\[E\]|Expected|Actual|Which|All tests passed|Some tests failed|Error' "$out" | tail -40 || true
  rm -f "$out"
done
exit $status
