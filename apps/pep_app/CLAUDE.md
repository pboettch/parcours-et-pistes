# pep_app (Flutter)

GUI proof of concept, web first; **parked** while the libraries are the focus — change it only
when asked, but keep it compiling (`flutter analyze`) when library APIs change. The user's GUI
direction is in memory (`project-gui-direction`): overview window, single-track window for
poseurs and judges.

## Structure
- `lib/state/` — `AppState` (identity, projects, session, own position, map state), `Storage`
  (shared_preferences; PoC: unencrypted), `DogSimulator` (bot walking a track, for tests).
- `lib/map/` — `MapScreen` (flutter_map: tracks, objects, places, members, dog path/progress,
  corridors), `BaseLayer` (IGN Plan, OSM Rando, OSM, IGN aerial).
- `lib/screens/` — menu screens (projects, tracks, runs, participants, settings).
- UI strings are French and inline (no i18n yet).

## Running
- `.claude/scripts/app.sh` — release build served on http://127.0.0.1:8686 (Browser pane preview
  config: `.claude/launch.json`); `run` = debug server; `build` = release only.
- Needs the dev broker (`.claude/scripts/broker.sh start`); new projects use `PEP_BROKER`.
- Private example project: `dart run .claude/scripts/seed_cco.dart` (memory `reference-cco-prototype`).

## Testing in the Browser pane
See memory `reference-dev-environment`: use the release build and `127.0.0.1:8686/?v=N`
(the pane caches `localhost`), click through semantics refs (`find`), and don't chase grey
tiles — the pane throttles rendering when unfocused.
