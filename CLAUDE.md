# Parcours et Pistes

Free, open-source (MIT) iOS / Android / web app to share trails of search-dog disciplines
(*Recherche Utilitaire* and *Man Trailing*). Projects, GPX tracks and live positions are shared
end-to-end encrypted over an MQTT broker; there is no central user database.

## Repository layout
- Dart workspace (root `pubspec.yaml`) with three pure Dart packages:
  - `packages/pep_channel/` — secure channel (transport, crypto, envelope, ACL, `SecureChannel`);
    never interprets item bodies.
  - `packages/pep_content/` — content model (GPX + pep extensions, Position, MemberProfile,
    ProjectInfo); no crypto, no MQTT.
  - `packages/pep_core/` — `ProjectSession` facade mapping content onto collections
    (`PepCollections`), the apps' API; `pep` CLI.
  New content type = data type in pep_content + collection in PepCollections.
- `apps/` — Flutter apps (later).
- `tools/broker/` — development MQTT 5 broker setup.
- `docs/DESIGN.md` — architecture, crypto, topic layout, phases.
- `.claude/memory/` — Claude memories (versioned; `~/.claude/projects/...-parcours-et-pistes/memory`
  is a symlink here). Index: `.claude/memory/MEMORY.md`.
- `.claude/scripts/` — helper scripts for Claude/dev tasks.

## Conventions
- Commit often: one commit per logical step; include memory updates in commits.
- Nothing project-related is ever published to MQTT unencrypted, except the `meta` topic
  (format version + KDF salt/params).
- Library code must run on the Dart VM and in the browser (no `dart:io` outside transport/CLI
  entry points guarded by conditional imports).

## Dev commands
- `source .claude/scripts/env.sh` — Flutter/Dart SDK on PATH (user-local in `/home/pmp/devel/flutter`).
- `.claude/scripts/broker.sh start|stop|status` — local mosquitto (MQTT 18883, WS 18080).
- `.claude/scripts/test.sh [-P pkg]... [args]` — `dart test` on VM + Chromium for all/given packages (`-x broker` skips broker tests).
- `.claude/scripts/e2e.sh` — end-to-end CLI scenario (owner + participant) on the dev broker.
- `dart run pep_core:pep --help` (in `packages/pep_core`) — CLI for manual testing.
- `.claude/scripts/coverage.sh` — merged LCOV (`coverage/lcov.info`) + Markdown summary.
- CI: `.github/workflows/ci.yml` (format, analyze, tests VM + Chrome with mosquitto, coverage).
  Code must pass `dart format` (page width 120) and `dart analyze --fatal-infos`.
