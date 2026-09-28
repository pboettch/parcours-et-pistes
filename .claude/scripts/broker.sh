#!/usr/bin/env bash
# Start/stop the local development MQTT broker (tools/broker/mosquitto.conf).
set -euo pipefail
dir="$(cd "$(dirname "$0")/../../tools/broker" && pwd)"
pidfile="$dir/data/mosquitto.pid"
bin="$(command -v mosquitto || echo /usr/sbin/mosquitto)"

running() { [[ -f $pidfile ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null; }

case "${1:-status}" in
  start)
    if running; then echo "already running (pid $(cat "$pidfile"))"; exit 0; fi
    mkdir -p "$dir/data" "$dir/log"
    (cd "$dir" && "$bin" -c mosquitto.conf -d)
    sleep 0.5
    pgrep -n -f "$bin -c mosquitto.conf" > "$pidfile"
    echo "started (pid $(cat "$pidfile")): mqtt://127.0.0.1:18883  ws://127.0.0.1:18080"
    ;;
  stop)
    if running; then kill "$(cat "$pidfile")"; rm -f "$pidfile"; echo stopped; else echo "not running"; fi
    ;;
  status)
    if running; then echo "running (pid $(cat "$pidfile"))"; else echo "not running"; exit 1; fi
    ;;
  *) echo "usage: $0 start|stop|status" >&2; exit 2 ;;
esac
