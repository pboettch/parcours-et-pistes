#!/usr/bin/env bash
# Download sodium.js (sumo) used by browser tests (dart test -p chrome) into packages/pep_core/test/web/.
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$(dirname "$0")/../../packages/pep_core"
dart run sodium:update_web --sumo --no-edit-index -d test/web
