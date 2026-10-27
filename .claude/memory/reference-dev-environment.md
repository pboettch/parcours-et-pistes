---
name: reference-dev-environment
description: Local dev environment (Flutter SDK path, sodium, mosquitto dev broker) and gotchas learned (libraries, CI, Flutter web in the Browser pane)
metadata:
  type: reference
---

**Environment:** Flutter SDK user-local at `/home/pmp/devel/flutter` (`source .claude/scripts/env.sh`).
`sodium` 4.x needs `SodiumSumoInit` (Argon2id); browser tests load sumo `sodium.js` via the
`dart_test.yaml` HTML template. Argon2id t=3/64 MiB ≈ 22 ms VM, 74 ms Chromium. System mosquitto
2.x; dev broker `.claude/scripts/broker.sh start` (18883 mqtt, 18080 ws, TLS/auth listeners),
persistent; it is not running after a reboot.

**Library gotchas:** mosquitto ACLs accept denied subscriptions (silently filtered) but refuse
denied QoS1 publishes (PUBACK 0x87); `archive`'s Inflate doesn't report corrupt streams (hence a
u32 length prefix); member ids are base64url and may start with `-` (CLI needs `--`); in dart2js
use multiplication, not `<<`, for u32.

**Workspace + Flutter:** Flutter pins `test_api`, so the packages use `test: ^1.25.0`; with
test 1.31 `CHROME_EXECUTABLE` is ignored when dart_test.yaml overrides chrome settings
(`test.sh` adds a `google-chrome` shim). CI uses the Flutter SDK.

**CI runner = Ubuntu 26.04** since ~2026-10-21 (`ubuntu-latest`; mosquitto 2.0.22). Its AppArmor 5
profile `mosquitto` (`/usr/sbin/mosquitto`) only allows `/etc/mosquitto/**`: the dev broker failed
with "Unable to open config file mosquitto.conf". Fix in ci.yml: `tools/broker/** rwk,` appended to
`/etc/apparmor.d/local/mosquitto` + `apparmor_parser -r`; `broker.sh` prints the same hint locally.

**Flutter web in the Browser pane** (learned on branch `poc-web`): debug (DDC) builds are slow/flaky →
release build (`app.sh serve` there);
the pane caches `localhost` → open `127.0.0.1:8686/?v=N`; coordinate clicks get lost on the
canvas → semantics on, click via `find` refs; the pane throttles requestAnimationFrame when
unfocused, so grey tiles there are a rendering artefact — never "fix" them with TileLayer resets
(that aborted tiles on every app event: Firefox NS_BINDING_ABORTED).

Related: [[project-overview]].
