# pep_app — Parcours et Pistes (Flutter)

GUI proof of concept, **web first** (Android/iOS scaffolding present, not yet worked on).
The app is a thin layer over `pep_core` (`ProjectSession`); see `docs/DESIGN.md`.

- Main screen: the map (IGN Plan, OSM Rando, OpenStreetMap, IGN aerial photos) centred on the user,
  with the project's tracks (objects, start/finish, places), members' positions and the dogs of runs
  (path, covered part and %, distance to the track, 100/200/300 m corridors).
- Menu: projects (join with link + password, create, invite), tracks (cards with level, poseur,
  Maps/Waze to the places), dogs on tracks (runs: create, designate the position source, start/finish,
  simulated dog for tests), participants (editors), settings (name, identity backup).

Run (fetches `sodium.js`, not versioned):

    .claude/scripts/app.sh          # release build served on http://127.0.0.1:8686
    .claude/scripts/app.sh run      # debug server

New projects use `PEP_BROKER` (default `ws://127.0.0.1:18080`, the dev broker of `tools/broker`).

PoC limitations: identity and project passwords are stored unencrypted in the browser
(localStorage); no background location; French UI strings inline (no i18n yet).
