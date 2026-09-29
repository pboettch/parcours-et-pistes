# Parcours et Pistes

[![CI](https://github.com/OWNER/REPO/actions/workflows/ci.yml/badge.svg)](https://github.com/OWNER/REPO/actions/workflows/ci.yml)

Share search-dog trails — *Recherche Utilitaire* (RU) and *Man Trailing* (MT) — between a
project creator and participants, with live position sharing. Available (later) for iOS,
Android and the web. Free and open source under the MIT license.

- Tracks are stored as GPX, **compressed and end-to-end encrypted** before being published.
- Everything belonging to a project lives on an MQTT broker under the project's secret UUID.
- No central user database; a default broker is preconfigured and can be replaced.

## Status
- Shared Dart libraries, complete and tested on the Dart VM and in browsers:
  - [`pep_channel`](packages/pep_channel) — secure channel: encryption, signatures, access
    control, MQTT 5 transport;
  - [`pep_content`](packages/pep_content) — content model: GPX with custom sections,
    positions, profiles, project info;
  - [`pep_core`](packages/pep_core) — project sessions (the apps' API) and the `pep` CLI.
- Flutter apps (iOS, Android, web): next.

Design and protocol: [`docs/DESIGN.md`](docs/DESIGN.md).

## Continuous integration
[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs on every push to `main` and on pull
requests: `dart format` check, `dart analyze`, the tests of each package on the Dart VM and in
Chrome (broker tests against a mosquitto started in the job), and a line-coverage report shown
in the run summary (uploaded to Codecov when the `CODECOV_TOKEN` secret is set). Locally:
`.claude/scripts/test.sh` and `.claude/scripts/coverage.sh`.

## License
MIT — see [LICENSE](LICENSE).
