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
# A straight 400 m track heading north, for the simulated dog.
{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo '<gpx version="1.1" creator="e2e" xmlns="http://www.topografix.com/GPX/1/1"><trk><name>Ligne</name><trkseg>'
  for i in $(seq 0 8); do printf '<trkpt lat="%s" lon="5.3"/>\n' "$(echo "45.2 + $i * 50 / 111195" | bc -l)"; done
  echo '</trkseg></trk></gpx>'
} > "$work/line.gpx"
O=(--identity "$work/owner.id"); A=(--identity "$work/alice.id"); B=(--identity "$work/bot.id")

step "owner creates project"
link=$(pep create "${O[@]}" -p pw1 --name "Forêt de Chambaran" --discipline ru --gpx "$work/trail.gpx" | tail -1)
echo "$link"
pid=$(sed 's/.*p=\([^&]*\).*/\1/' <<<"$link")
alice=$(pep id "${A[@]}" | tail -1)
owner_dummy=$(pep id --identity "$work/nobody.id" | tail -1) # a member who never joins

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

step "owner pushes a hidden track, then shares it with alice"
hidden=$(pep push "$link" "${O[@]}" -p pw1 --gpx "$work/trail.gpx" --name "Piste cachée" --visible-to "$owner_dummy" | cut -d' ' -f1)
! pep info "$link" "${A[@]}" -p pw1 | grep -q "Piste cachée"
echo "alice does not see it"
pep push "$link" "${O[@]}" -p pw1 --gpx "$work/trail.gpx" --name "Piste cachée" --id "$hidden" --visible-to "$alice"
pep info "$link" "${A[@]}" -p pw1 | grep "Piste cachée"

step "alice backs up her identity and restores it on a 'new device'"
backup=$(pep identity export "${A[@]}" --passphrase "sésame")
echo "backup: ${backup:0:24}… (${#backup} chars)"
restored=$(pep identity import "$backup" --identity "$work/alice-tablet.id" --passphrase "sésame" | tail -1)
[[ $restored == "$alice" ]] && echo "same member id on the new device"
pep pos "$link" --identity "$work/alice-tablet.id" --device tablet -p pw1 45.2010 5.3010

step "a run: the owner designates the collar bot as the dog's position; simulated dog"
bot=$(pep id "${B[@]}" | tail -1)
pep name "$link" "${B[@]}" -p pw1 --bot "Tractive"
line=$(pep push "$link" "${O[@]}" -p pw1 --gpx "$work/line.gpx" | cut -d' ' -f1)
run=$(pep run "$link" "${O[@]}" -p pw1 add --track "$line" --dog Rex --handler Ana --source "$bot" | tail -1)
pep run "$link" "${O[@]}" -p pw1 start "$run"
pep replay "$link" "${B[@]}" -p pw1 "$work/line.gpx" --speed 2 --rate 50 --interval 5
pep run "$link" "${A[@]}" -p pw1 list | tee "$work/run.txt"
grep -Eq "Rex / Ana on $line, running, source Tractive .*, (9[0-9]|100)%" "$work/run.txt"
pep run "$link" "${O[@]}" -p pw1 finish "$run"

step "broker view (admin wildcard): only meta is plaintext, no member ids in topics"
mosquitto_sub -V mqttv5 -p 18883 -t "pep/v1/$pid/#" -W 1 -F '%t %l bytes, starts with: %x' 2>/dev/null \
  | sed -E 's/(starts with: .{16}).*/\1…/' || true

! mosquitto_sub -V mqttv5 -p 18883 -t "pep/v1/$pid/#" -W 1 -F '%t' 2>/dev/null | grep -q -- "$alice"

step "owner hands the project over to alice"
pep owner "${O[@]}" -p pw1 "$link" offer -- "$alice"
pep owner "${A[@]}" -p pw1 "$link" accept
pep info "$link" "${A[@]}" -p pw1 | grep "owner"
! pep passwd "$link" "${O[@]}" -p pw1 --new nope

step "new owner changes the password"
pep passwd "$link" "${A[@]}" -p pw1 --new pw2
! pep info "$link" "${O[@]}" -p pw1
pep info "$link" "${O[@]}" -p pw2

step "new owner deletes the project"
pep delete "$link" "${A[@]}" -p pw2
left=$(mosquitto_sub -V mqttv5 -p 18883 -t "pep/v1/$pid/#" -W 1 -F '%t' 2>/dev/null | wc -l || true)
echo "retained messages left: $left"
sleep 1

step "owner watch log"
cat "$work/watch.log"
[[ $left -eq 0 ]]
echo; echo "E2E OK"
