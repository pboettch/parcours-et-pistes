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
items: envelope, owner-signed ACL declaring collections with writer policies owner/assigned/self +
TTL; one writer per item, see [[project-runs-dog-path]]), `pep_content` (data types, geometry; no crypto/MQTT) and `pep_core` (`ProjectSession`,
`PepCollections`, CLI). New content type = type in pep_content + collection in PepCollections;
collections are declared in the ACL so older apps still enforce their rules.

**Track content = GPX only (user):** RU objects are waypoints `<type>pep:object</type>`; everything
about a track travels in the GPX, custom sections in namespace `urn:parcours-et-pistes:gpx:1`.
The official RU trail sheet (organizers' part + judge's part, printable documents) comes later —
placeholders only (`TrailInfo`).

**Focus (user, 2026-10-18):** "forget the PoC for the moment, we only work on the low-level lib";
the app layer for the three platforms comes soon. The web PoC is not on `main` (branch `poc-web`,
see [[project-gui-direction]]).

**Status (2026-10-27):** libraries complete and tested (VM + Chromium, memory broker + mosquitto),
CI green on `main`; `pep` CLI and `.claude/scripts/e2e.sh` pass; web GUI PoC on the unmerged
branch `poc-web`. PR #3 (runs, recorder-only dog path, per-track owners, no password change, no
ownership transfer — [[project-no-password-change]]) was merged on 2026-10-19 (`f976ba8`); its
history had been rewritten into a few clean commits on the user's request (old commits on the
local branch `archive/runs-dog-path-pre-rewrite`). The user runs the protocol-reviewer at
effort xhigh.
2026-10-27, branch `docs-sync`: docs, READMEs, memory and code comments checked against the code
and aligned; e2e covers every CLI command and its refusal checks now really fail the script;
`IdentityBackup` renamed `IdentityExport` ([[project-identity-devices]]).

**Open topics:** library bug: TTL bounds not checked when an access list is written
(`.claude/reviews/2026-10-27-docs-sync.md`); create a project from a local copy (`docs/TODO.md`); IdentityExport activation code / passphrase rules ([[project-identity-devices]]); RU details from the user;
default production broker + wildcard restriction; background location; app deep-link domain.

Related: [[project-identity-devices]], [[project-runs-dog-path]], [[project-gui-direction]],
[[reference-dev-environment]], [[feedback-repo-conventions]].
