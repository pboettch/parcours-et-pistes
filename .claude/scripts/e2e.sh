#!/usr/bin/env bash
# End-to-end scenario with the pep CLI against the local dev broker:
# owner creates a project with a GPX, watches live; a participant joins, shares
# name + position, becomes editor, pushes a track; owner changes the password
# and deletes the project. Requires .claude/scripts/broker.sh start.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$root/.claude/scripts/env.sh"
cd "$root/packages/pep_core"
work="$(mktemp -d)"
trap 'kill ${watch_pid:-0} 2>/dev/null || true; rm -rf "$work"' EXIT
pep() { dart run pep_core:pep "$@" 2> >(sed 's/^\(Running build hooks\.\.\.\)*//' | grep -v '^$' >&2); }
step() { printf '\n== %s\n' "$*"; }

cat > "$work/trail.gpx" <<'GPX'
<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="e2e" xmlns="http://www.topografix.com/GPX/1/1">
  <wpt lat="45.2001" lon="5.3002"><name>Objet 1</name><type>pep:object</type></wpt>
  <trk><name>Piste du samedi</name><trkseg>
    <trkpt lat="45.2000" lon="5.3000"/><trkpt lat="45.2003" lon="5.3003"/>
  </trkseg></trk>
</gpx>
GPX
O=(--identity "$work/owner.id"); A=(--identity "$work/alice.id")

step "owner creates project"
link=$(pep create "${O[@]}" -p pw1 --name "Forêt de Chambaran" --discipline ru --gpx "$work/trail.gpx" | tail -1)
echo "$link"
pid=$(sed 's/.*p=\([^&]*\).*/\1/' <<<"$link")
alice=$(pep id "${A[@]}" | tail -1)

step "owner watches (background)"
pep watch "$link" "${O[@]}" -p pw1 > "$work/watch.log" 2>&1 & watch_pid=$!
sleep 3

step "alice: info, wrong password, name, position"
pep info "$link" "${A[@]}" -p pw1
! pep info "$link" "${A[@]}" -p wrong
pep name "$link" "${A[@]}" -p pw1 "Alice et Rex"
pep pos "$link" "${A[@]}" -p pw1 45.2002 5.3001 --acc 4

step "alice cannot push; owner makes her editor; alice pushes"
! pep push "$link" "${A[@]}" -p pw1 --gpx "$work/trail.gpx"
pep editor "${O[@]}" -p pw1 "$link" add -- "$alice"
pep push "$link" "${A[@]}" -p pw1 --gpx "$work/trail.gpx" --name "Variante Alice"

step "broker view (admin wildcard): only meta is plaintext"
mosquitto_sub -V mqttv5 -p 18883 -t "pep/v1/$pid/#" -W 1 -F '%t %l bytes, starts with: %x' 2>/dev/null \
  | sed -E 's/(starts with: .{16}).*/\1…/' || true

step "owner changes password"
pep passwd "$link" "${O[@]}" -p pw1 --new pw2
! pep info "$link" "${A[@]}" -p pw1
pep info "$link" "${A[@]}" -p pw2

step "owner deletes the project"
pep delete "$link" "${O[@]}" -p pw2
left=$(mosquitto_sub -V mqttv5 -p 18883 -t "pep/v1/$pid/#" -W 1 -F '%t' 2>/dev/null | wc -l || true)
echo "retained messages left: $left"
sleep 1

step "owner watch log"
cat "$work/watch.log"
[[ $left -eq 0 ]]
echo; echo "E2E OK"
