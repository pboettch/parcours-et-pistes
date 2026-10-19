# Libraries (pep_channel, pep_content, pep_core)

Pure Dart, VM + browser. The protocol and threat model are in `docs/DESIGN.md`; read the relevant
section before changing behaviour, and update it in the same commit.

## Layering
- `pep_channel` — transport, crypto, envelope, ACL, `SecureChannel`. Never interprets item bodies.
- `pep_content` — data types, GPX + `pep` extensions, geometry (`TrackLine`, `TrailProgress`,
  `TrailWalker`, `simulateTrail`). No crypto, no MQTT.
- `pep_core` — `ProjectSession` (the apps' API) maps content onto channel collections
  (`PepCollections`); `pep` CLI in `bin/pep.dart`.
- Dependencies point one way: `pep_core` → `pep_channel`, `pep_content`. Nothing else.

## Invariants (do not break silently)
- Nothing project-related on MQTT in clear except `meta` (format version, KDF salt/params).
- Every item is signed by its writer and encrypted with the topic as associated data.
- Member ids and device names never appear in topics (per-channel pseudonyms, keyed device tags).
- Access rules live in the owner-signed ACL; collections are declared there, so older apps keep
  enforcing rules for content types they don't know (and ignore their content).
- Forward compatibility: JSON documents carry `v` and keep unknown fields (`extra`); GPX keeps
  unknown extensions. A wire-format change means a new version, documented in DESIGN.md.
- No identity transfer over the broker (user decision); identities move via `IdentityBackup`.
- No `dart:io` in `lib/` except behind the transport's conditional imports. In dart2js, use
  multiplication instead of `<<` for 32-bit values.

## Adding things
- New content type = data type in `pep_content` + collection (with writer policy) in
  `PepCollections.defaults`; `ProjectSession.ensureCollections` adds it to older projects.
- Behaviour that must hold on every transport goes into the contract tests
  (`pep_channel/test/support/channel_contract.dart`, `pep_core/test/support/session_contract.dart`),
  which run on the memory broker (fake clock) and on mosquitto. Async results: `eventually(...)`.
- CLI commands get a step in `.claude/scripts/e2e.sh`.

## Checks before committing
- `dart format` (page width 120), `dart analyze --fatal-infos packages`.
- `.claude/scripts/test.sh [-P pkg]` (VM + Chromium; broker tests need `broker.sh start`).
- `.claude/scripts/e2e.sh` when the CLI or session behaviour changed.
- For changes to crypto, envelope, ACL, topics or session semantics, have the
  `protocol-reviewer` agent review the diff before committing, and address what it finds.
