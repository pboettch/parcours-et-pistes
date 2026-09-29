#!/usr/bin/env bash
# Start/stop the local development MQTT broker (tools/broker/mosquitto.conf).
set -euo pipefail
dir="$(cd "$(dirname "$0")/../../tools/broker" && pwd)"
pidfile="$dir/data/mosquitto.pid"
bin="$(command -v mosquitto || echo /usr/sbin/mosquitto)"

running() { [[ -f $pidfile ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null; }

# Test CA + server certificate for 127.0.0.1/localhost, and the dev password file.
prepare() {
  local c="$dir/certs"
  mkdir -p "$c" "$dir/data" "$dir/log"
  if [[ ! -f $c/server.pem ]]; then
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3650 \
      -subj "/CN=pep dev test CA" -keyout "$c/ca.key" -out "$c/ca.pem" 2>/dev/null
    openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
      -subj "/CN=localhost" -keyout "$c/server.key" -out "$c/server.csr" 2>/dev/null
    openssl x509 -req -in "$c/server.csr" -CA "$c/ca.pem" -CAkey "$c/ca.key" -CAcreateserial \
      -days 3650 -out "$c/server.pem" \
      -extfile <(printf 'subjectAltName=IP:127.0.0.1,DNS:localhost\nextendedKeyUsage=serverAuth') 2>/dev/null
    rm -f "$c/server.csr" "$c/ca.srl"
    openssl x509 -in "$c/server.pem" -outform der | openssl dgst -sha256 -r | cut -d' ' -f1 > "$c/server.sha256"
    echo "generated test certificates (server sha256 $(cat "$c/server.sha256"))"
  fi
  chmod 600 "$dir/acl"
  if [[ ! -f $dir/passwd ]]; then
    mosquitto_passwd -c -b "$dir/passwd" pep pep-secret
    chmod 600 "$dir/passwd"
  fi
}

case "${1:-status}" in
  start)
    if running; then echo "already running (pid $(cat "$pidfile"))"; exit 0; fi
    prepare
    (cd "$dir" && "$bin" -c mosquitto.conf -d)
    sleep 0.5
    pgrep -n -f "$bin -c mosquitto.conf" > "$pidfile"
    echo "started (pid $(cat "$pidfile")): mqtt :18883  ws :18080  mqtts :18884  wss :18443  auth :18885"
    ;;
  stop)
    if running; then kill "$(cat "$pidfile")"; rm -f "$pidfile"; echo stopped; else echo "not running"; fi
    ;;
  status)
    if running; then echo "running (pid $(cat "$pidfile"))"; else echo "not running"; exit 1; fi
    ;;
  *) echo "usage: $0 start|stop|status" >&2; exit 2 ;;
esac
