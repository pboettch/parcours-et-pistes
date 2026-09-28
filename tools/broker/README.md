# Development MQTT broker

`mosquitto.conf` runs a local MQTT 5 broker for tests and the `pep` CLI:

| Listener | Port  | Use                     |
|----------|-------|-------------------------|
| MQTT     | 18883 | Dart VM tests, CLI      |
| WS       | 18080 | Browser (`-p chrome`)   |

Start/stop with `.claude/scripts/broker.sh start|stop|status` (requires the `mosquitto`
binary, e.g. `sudo apt install mosquitto`). Anonymous access, localhost only.

## Production requirements (not covered here)
- TLS on both MQTT and WebSocket listeners.
- MQTT 5 with message expiry support (positions expire).
- Retained messages persisted indefinitely.
- **Forbid wildcard subscriptions above the project-UUID level** (e.g. `pep/v1/#`,
  `pep/v1/+/...`) for regular accounts, so project UUIDs cannot be enumerated. Plain mosquitto
  ACLs cannot express "allow any literal UUID but no wildcard there"; use an auth plugin
  (e.g. mosquitto-go-auth) or a broker with richer authorization (e.g. EMQX).
- Optionally, restrict writes to `pep/v1/<uuid>/project` and `.../track/#` per project.
