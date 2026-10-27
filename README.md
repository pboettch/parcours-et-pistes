# Parcours et Pistes

[![CI](https://github.com/pboettch/parcours-et-pistes/actions/workflows/ci.yml/badge.svg)](https://github.com/pboettch/parcours-et-pistes/actions/workflows/ci.yml)

Share search-dog trails — *Recherche Utilitaire* (RU) and *Man Trailing* (MT) — between a
project creator and participants, with live position sharing. Available (later) for iOS,
Android and the web. Free and open source under the MIT license.

- Tracks are stored as GPX, **compressed and end-to-end encrypted** before being published.
- Everything belonging to a project lives on an MQTT broker under the project's secret UUID;
  nothing is published in clear but `meta` (key-derivation parameters and a key check), and
  topics carry random ids and pseudonyms, never member ids.
- No central user database: a member is a key pair, and joining takes a link plus the
  project's password. A default broker is preconfigured and can be replaced.
- Every item has a single writer, set in an access list signed by the project owner: the owner
  (project info, runs), the member a track is assigned to, or the member an item belongs to
  (profile, positions, recorded path).
- At events, the dog's position comes from a member the owner designates (its follower, or a
  bot feeding a GPS collar); that member's devices record the dog's path, and everyone sees
  how far the dog has come along the track.

## Status
- Shared Dart libraries, complete and tested on the Dart VM and in browsers:
  - [`pep_channel`](packages/pep_channel) — secure channel: encryption, signatures, access
    control, pseudonymous topics, per-track visibility, identity export, MQTT 5 transport;
  - [`pep_content`](packages/pep_content) — content model: GPX with custom sections (RU
    objects, places, trail details), positions, profiles, project info, runs, recorded paths;
    track geometry, progress matching and simulated trails;
  - [`pep_core`](packages/pep_core) — project sessions (the apps' API: tracks with one owner
    each, positions per device, runs and the dog's recorded path) and the `pep` CLI.
- Flutter apps (iOS, Android, web): next. A web GUI proof of concept lives on the unmerged branch
  [`poc-web`](https://github.com/pboettch/parcours-et-pistes/tree/poc-web); parts of it will be reused.
- App-layer work still to do: [`docs/TODO.md`](docs/TODO.md).

Design, protocol and threat model: [`docs/DESIGN.md`](docs/DESIGN.md).

## Repository layout
- `packages/` — the three libraries (a Dart workspace, root `pubspec.yaml`).
- `docs/` — design and protocol, app-layer TODOs.
- `tools/broker/` — development MQTT 5 broker ([README](tools/broker/README.md)).
- `.claude/` — scripts, notes and agents used for development with Claude Code.

## Development
Needs Dart ≥ 3.9 (or Flutter stable), `mosquitto` for the broker tests and Chromium for the
browser tests. From the repository root:

```bash
source .claude/scripts/env.sh          # user-local Flutter/Dart SDK, if any
.claude/scripts/broker.sh start        # local mosquitto: mqtt :18883, ws :18080, mqtts :18884, wss :18443, auth :18885
.claude/scripts/test.sh                # all packages, VM and Chromium
.claude/scripts/test.sh -P pep_channel # one package
.claude/scripts/test.sh -x broker      # without the broker integration tests
.claude/scripts/e2e.sh                 # end-to-end scenario with the CLI, every command
.claude/scripts/coverage.sh            # merged line coverage (coverage/lcov.info + summary)
dart run .claude/scripts/seed_example.dart   # example project with simulated, fictional trails
```

CLI for manual testing: `dart run pep_core:pep --help` (in `packages/pep_core`). Code must pass
`dart format` (page width 120) and `dart analyze --fatal-infos packages`.

## Continuous integration
[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs on every push to `main` and on pull
requests (Flutter SDK, stable): `dart format` check, `dart analyze`, the tests of each package on
the Dart VM and in Chrome (broker tests against a mosquitto started in the job), and a
line-coverage report shown in the run summary (uploaded to Codecov when the `CODECOV_TOKEN`
secret is set).

## License
MIT — see [LICENSE](LICENSE).
