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
- Topic layout `pep/v1/<uuid>/{meta,project,track/<id>,member/<id>,pos/<id>}`.
- Full plan: see git history / `CLAUDE.md`. Conventions: [[feedback-repo-conventions]].
