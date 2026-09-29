#!/usr/bin/env bash
# Runs the Flutter web app (apps/pep_app) on http://127.0.0.1:${PORT:-8686}.
#   .claude/scripts/app.sh [serve|run|build]
#     serve: release build, served statically (default); run: debug server; build: release in build/web
# Fetches sodium.js (not versioned) first. Broker for new projects: PEP_BROKER.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$root/.claude/scripts/env.sh"
cd "$root/apps/pep_app"
[[ -f web/sodium.js ]] || dart run sodium:update_web --sumo --no-edit-index
defines=(--dart-define=PEP_BROKER="${PEP_BROKER:-ws://127.0.0.1:18080}")
case "${1:-serve}" in
  serve)
    flutter build web --release "${defines[@]}"
    exec python3 -m http.server "${PORT:-8686}" --bind 127.0.0.1 --directory build/web ;;
  run) exec flutter run -d web-server --web-hostname 127.0.0.1 --web-port "${PORT:-8686}" "${defines[@]}" ;;
  build) exec flutter build web --release "${defines[@]}" ;;
  *) echo "usage: $0 [serve|run|build]" >&2; exit 64 ;;
esac
