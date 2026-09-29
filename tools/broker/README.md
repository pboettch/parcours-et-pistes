# Development MQTT broker

`mosquitto.conf` runs a local MQTT 5 broker for tests and the `pep` CLI:

| Listener | Port  | Use                                                        |
|----------|-------|------------------------------------------------------------|
| MQTT     | 18883 | Dart VM tests, CLI (anonymous)                             |
| WS       | 18080 | Browser tests (anonymous)                                  |
| MQTTS    | 18884 | TLS tests (anonymous, test certificate)                    |
| WSS      | 18443 | Secure WebSocket tests (anonymous, test certificate)       |
| MQTT     | 18885 | Auth/ACL tests: user `pep` / `pep-secret`, `pep-acl/allowed/#` only |

Start/stop with `.claude/scripts/broker.sh start|stop|status` (requires `mosquitto`,
`mosquitto_passwd` and `openssl`). On first start it generates a test CA and a server
certificate for 127.0.0.1/localhost in `certs/` (its SHA-256 fingerprint in
`certs/server.sha256`, used as a pin by the VM tests) and the password file `passwd`. None of
these are committed. Localhost only.

Note: mosquitto's ACL accepts subscriptions to denied topics and silently filters delivery;
denied publishes get PUBACK reason 0x87 (reported by the library as `TransportException`).

## Production requirements (not covered here)
- TLS on both MQTT and WebSocket listeners.
- MQTT 5 with message expiry support (positions expire).
- Retained messages persisted indefinitely.
- **Forbid wildcard subscriptions above the project-UUID level** (e.g. `pep/v1/#`,
  `pep/v1/+/...`) for regular accounts, so project UUIDs cannot be enumerated. Plain mosquitto
  ACLs cannot express "allow any literal UUID but no wildcard there"; use an auth plugin
  (e.g. mosquitto-go-auth) or a broker with richer authorization (e.g. EMQX).
- Optionally, restrict writes to `pep/v1/<uuid>/project` and `.../track/#` per project.
