#!/usr/bin/env bash
# Line coverage of all packages (Dart VM tests), merged into coverage/lcov.info
# (paths relative to the repository root) plus a Markdown summary in
# coverage/summary.md. Broker tests are included when the dev broker runs
# (.claude/scripts/broker.sh start); pass -x broker to skip them.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$root/.claude/scripts/env.sh"
rm -rf "$root/coverage" && mkdir -p "$root/coverage"
for p in pep_content pep_channel pep_core; do
  cd "$root/packages/$p"
  rm -rf coverage
  dart test -p vm --coverage=coverage "$@"
  dart run coverage:format_coverage --lcov --check-ignore --in=coverage \
    --out="$root/coverage/$p.lcov.info" --report-on=lib --base-directory="$root"
done
cat "$root"/coverage/*.lcov.info > "$root/coverage/lcov.info"
python3 "$root/.claude/scripts/coverage_summary.py" "$root/coverage/lcov.info" | tee "$root/coverage/summary.md"
