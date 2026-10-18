# Parcours et Pistes

Free, open-source (MIT) iOS / Android / web app to share trails of search-dog disciplines
(*Recherche Utilitaire* and *Man Trailing*). Projects, GPX tracks and live positions are shared
end-to-end encrypted over an MQTT broker; there is no central user database.

## Repository layout
- Dart workspace (root `pubspec.yaml`) with three pure Dart packages:
  - `packages/pep_channel/` — secure channel (transport, crypto, envelope, ACL, `SecureChannel`);
    never interprets item bodies.
  - `packages/pep_content/` — content model (GPX + pep extensions, Position, MemberProfile, Run,
    ProjectInfo, TrailInfo) + geometry/progress/simulation; no crypto, no MQTT.
  - `packages/pep_core/` — `ProjectSession` facade mapping content onto collections
    (`PepCollections`), the apps' API; `pep` CLI.
  Library rules and checks: `packages/CLAUDE.md`.
- `apps/` — Flutter apps (next). A web GUI proof of concept lives on the unmerged branch `poc-web`
  (parts will be reused; the real app's design will differ).
- `tools/broker/` — development MQTT 5 broker setup.
- `docs/DESIGN.md` — architecture, crypto, protocol, threat model.
- `docs/TODO.md` — app-layer TODOs (friends, device sync, UI flows).
- `.claude/memory/` — Claude memories (versioned; `~/.claude/projects/...-parcours-et-pistes/memory`
  is a symlink here). Index: `.claude/memory/MEMORY.md`.
- `.claude/scripts/` — helper scripts for Claude/dev tasks.
- `.claude/agents/` — subagents (e.g. `protocol-reviewer`: read-only review of library changes).

## Conventions
- Commit often: one commit per logical step; include memory updates in commits.
- Nothing project-related is ever published to MQTT unencrypted, except the `meta` topic
  (format version + KDF salt/params).
- Library code must run on the Dart VM and in the browser (see `packages/CLAUDE.md`).

## Working in sessions
- One topic per session (e.g. "IdentityExport", "Android background location"); the state lives
  in the repo, not in the conversation: memory (`.claude/memory/`), `docs/DESIGN.md`,
  `docs/TODO.md`.
- Before a session ends: record the user's decisions and open questions in memory, update the
  docs, commit.
- Use subagents for fresh eyes: independent design proposals, the `protocol-reviewer` for
  library changes, exploration whose details don't need to stay in context.
- Separate workstreams (libraries, app, later platform specifics) go on their own branches;
  parallel sessions use separate git worktrees.

## Dev commands
- `source .claude/scripts/env.sh` — Flutter/Dart SDK on PATH (user-local in `/home/pmp/devel/flutter`).
- `.claude/scripts/broker.sh start|stop|status` — local mosquitto (MQTT 18883, WS 18080).
- `.claude/scripts/test.sh [-P pkg]... [args]` — `dart test` on VM + Chromium for all/given packages (`-x broker` skips broker tests).
- `.claude/scripts/e2e.sh` — end-to-end CLI scenario (owner + participant) on the dev broker.
- `dart run pep_core:pep --help` (in `packages/pep_core`) — CLI for manual testing.
- `.claude/scripts/coverage.sh` — merged LCOV (`coverage/lcov.info`) + Markdown summary.
- `dart run .claude/scripts/seed_cco.dart` — private example project from the local CCO site copy
  (see memory `reference-cco-prototype`); link/password saved outside the repo.
- CI: `.github/workflows/ci.yml` (format, analyze, tests VM + Chrome with mosquitto, coverage).
  Code must pass `dart format` (page width 120) and `dart analyze --fatal-infos`.
