---
name: project-overview
description: Parcours et Pistes — what it is, the user's requirements, core technical decisions, package architecture, current focus and status
metadata:
  type: project
---

**Goal:** free, open-source (MIT, GitHub, App Store + Play Store) app for iOS, Android and web to
share trails of the French search-dog discipline *Recherche Utilitaire* (RU) and *Man Trailing* (MT).

**User requirements (2026-09-29):**
- A user creates a *project*, imports GPX tracks (track creation/recording in the app: later).
- RU tracks = track + objects (+ more info); MT = track only.
- Shared with a link + a password; tracks **never published unencrypted**.
- Participants live-share positions; positions expire, tracks are retained indefinitely.
- Everything lives on an MQTT broker under the project UUID topic; **no central user database**.
- Default broker preconfigured, replaceable. Background location sharing on iOS/Android
  (OwnTracks = behavioural reference only, no interoperability).
- The creator delegates update rights; the UUID is a secret (broker should forbid wildcard
  subscriptions above the UUID level).

**Core decisions:** shared low-level library first, then the apps. Apps in **Flutter** → pure Dart
packages (VM + web). libsodium (`sodium`): Argon2id from the password, XChaCha20-Poly1305 with the
topic as AD, Ed25519 identities, deflate before encrypting. MQTT 5 (`mqtt5_client`) behind a
pluggable `Transport`. Full protocol: `docs/DESIGN.md`.

**Architecture (user request):** Dart workspace with `pep_channel` (secure channel over opaque
items: envelope, owner-signed ACL declaring collections with writer policies owner/editors/self +
TTL), `pep_content` (data types, geometry; no crypto/MQTT) and `pep_core` (`ProjectSession`,
`PepCollections`, CLI). New content type = type in pep_content + collection in PepCollections;
collections are declared in the ACL so older apps still enforce their rules.

**Track content = GPX only (user):** RU objects are waypoints `<type>pep:object</type>`; everything
about a track travels in the GPX, custom sections in namespace `urn:parcours-et-pistes:gpx:1`.
The official RU trail sheet (organizers' part + judge's part, printable documents) comes later —
placeholders only (`TrailInfo`).

**Focus (user, 2026-10-18):** "forget the PoC for the moment, we only work on the low-level lib";
the app layer for the three platforms comes soon. The web PoC is not on `main` (branch `poc-web`,
see [[project-gui-direction]]).

**Status (2026-10-18):** libraries complete and tested (VM + Chromium, memory broker + mosquitto),
`pep` CLI and `.claude/scripts/e2e.sh` pass; web GUI PoC on the unmerged branch `poc-web`.
PR #2 (branch `app-poc`, libraries + tooling only, app removed) brings runs, dog path, `purge`.

**PR #2 under the user's review (2026-10-18):** they will go through the branch in a new session —
"there are things I don't like"; wait for their points before changing or merging anything.

**Open topics:** dog-path bugs from the first review ([[project-runs-dog-path]]); IdentityBackup helpers ([[project-identity-devices]]); RU details from the user;
default production broker + wildcard restriction; background location; app deep-link domain.

Related: [[project-identity-devices]], [[project-runs-dog-path]], [[project-gui-direction]],
[[reference-dev-environment]], [[feedback-repo-conventions]].
