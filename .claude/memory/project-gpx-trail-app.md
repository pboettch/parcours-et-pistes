---
name: project-gpx-trail-app
description: Parcours et Pistes — iOS/Android/web app to share encrypted GPX trails for search-dog disciplines (RU, Man Trailing) over MQTT; goals, constraints and core-library design decisions
metadata:
  type: project
---

**Goal:** free, open-source (MIT, GitHub) app for iOS, Android and web to share trails of the
French search-dog discipline *Recherche Utilitaire* (RU) and international *Man Trailing* (MT).
Small user base, but published on App Store and Play Store.

**Functional summary (from the user, 2026-09-29):**
- Any user creates a *project*, imports GPX tracks (later: create/edit tracks + surrounding info).
- RU tracks: track + object positions + more info (details TBD). MT tracks: track only, no objects.
- Creator shares a link + a password; others receive and decrypt the tracks.
- Tracks are **never published unencrypted** (compressed, then encrypted).
- Creator and participants live-share positions; everyone in the same project sees each other.
- Transport: MQTT server; the project UUID is an endpoint in the topic. Track updates are
  published retained (replace previous version, kept indefinitely). Positions are retained too but
  disappear after a configured time.
- All project data/settings live on the MQTT project topic. **No central user database.**
- A default MQTT server/account is preconfigured; users can configure another one.
- Background position sharing on iOS/Android is required (OwnTracks = behavioural reference only,
  we do NOT interoperate with its format).
- The creator can delegate update rights to other users. The UUID is a secret; ideally the broker
  forbids wildcard subscriptions above the UUID level so only the admin can enumerate projects.
- The user said more details will follow later.

**Decisions taken (2026-09-29):**
- Build a shared low-level library first (`packages/pep_core`), full functional coverage, then apps.
- Apps in **Flutter** → library is a **pure Dart package** (VM + web).
- Crypto: libsodium (`sodium` Dart package; Flutter apps inject `sodium_libs`). Argon2id KDF from
  password (+ salt/params in plaintext `meta` topic), XChaCha20-Poly1305 AEAD with topic as AD,
  Ed25519 device identities; owner signs project doc listing editor keys; tracks signed by
  owner/editor; positions signed by sender. Deflate before encrypt.
- Join link: UUID + owner key fingerprint (+ optional broker) in URL fragment; password separate.
- MQTT 5 (`mqtt5_client`) behind a pluggable `Transport` interface; positions use message expiry
  plus client-side TTL filter.
- Topic layout `pep/v1/<uuid>/{meta,project,track/<id>,member/<id>,pos/<id>,sync/<nonce>}`.
- Changed during implementation (see docs/DESIGN.md): `meta` is owner-signed + revisioned (else
  anyone knowing the UUID could fake a password change); no track index in the project doc
  (editors couldn't update an owner-signed index) — tracks discovered via retained topics,
  deletion = signed tombstone; `join()` waits on a sync barrier (empty non-retained probe) so
  state is complete; password change publishes new meta first.
- Full design: `docs/DESIGN.md`. Conventions: [[feedback-repo-conventions]].

**Spike results (2026-09-29):** Flutter SDK is user-local at `/home/pmp/devel/flutter` (Dart 3.13.4;
`source .claude/scripts/env.sh`). `sodium` 4.x needs `SodiumSumoInit` for Argon2id; browser tests load
sumo `sodium.js` via `dart_test.yaml` HTML template. Argon2id t=3/64 MiB: ~22 ms VM, ~74 ms Chromium →
chosen as default KDF params. System mosquitto 2.1.2 installed; dev broker via `.claude/scripts/broker.sh`
(ports 18883/18080) and retained-message expiry verified working.

**Track content = GPX only (user decision, 2026-09-29):** RU objects are GPX waypoints
(`<type>pep:object</type>`); *everything* related to a track travels in the GPX, with additional
custom sections as `<extensions>` in namespace `urn:parcours-et-pistes:gpx:1` (prefix `pep`). The
TrackDoc JSON wrapper carries only id/rev/upd/deleted + gpx. Concrete RU extension elements: TBD
by the user.

**Status (2026-09-29):** `packages/pep_core` phases 1–6 done and committed: 213 test runs green
(VM + Chromium; memory broker + mosquitto TCP/TLS/WS/WSS/auth), ~96 % line coverage, `pep` CLI and
`.claude/scripts/e2e.sh` pass. **Next: Flutter apps** (user wants to start them once the library is
done). Open topics for later: RU-specific track info (user will detail), default production broker
+ wildcard-subscription restriction, background location in the apps, app deep-link domain.

**Gotchas learned:** mosquitto ACLs accept denied subscriptions (silently filtered) but refuse denied
QoS1 publishes with PUBACK 0x87; `archive`'s Inflate doesn't report corrupt streams (hence the u32
length prefix); member ids are base64url and may start with `-` (CLI needs `--`); in dart2js use
multiplication not `<<` for u32.
