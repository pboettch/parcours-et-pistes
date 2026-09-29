# Parcours et Pistes

Free, open-source (MIT) iOS / Android / web app to share trails of search-dog disciplines
(*Recherche Utilitaire* and *Man Trailing*). Projects, GPX tracks and live positions are shared
end-to-end encrypted over an MQTT broker; there is no central user database.

## Repository layout
- `packages/pep_core/` — pure Dart shared library (crypto, envelope, models, GPX, topics,
  transport, high-level `ProjectSession`). Built and fully tested before any app work.
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
- `.claude/scripts/test.sh [args]` — `dart test` on VM + Chromium (`-x broker` skips broker tests).
- `.claude/scripts/e2e.sh` — end-to-end CLI scenario (owner + participant) on the dev broker.
- `dart run pep_core:pep --help` (in `packages/pep_core`) — CLI for manual testing.
