# Parcours et Pistes

Share search-dog trails — *Recherche Utilitaire* (RU) and *Man Trailing* (MT) — between a
project creator and participants, with live position sharing. Available (later) for iOS,
Android and the web. Free and open source under the MIT license.

- Tracks are stored as GPX, **compressed and end-to-end encrypted** before being published.
- Everything belonging to a project lives on an MQTT broker under the project's secret UUID.
- No central user database; a default broker is preconfigured and can be replaced.

## Status
- `packages/pep_core` — shared Dart library (crypto, protocol, MQTT transport, project
  sessions, GPX): functionally complete and tested on the Dart VM and in browsers.
  See [`packages/pep_core/README.md`](packages/pep_core/README.md).
- Flutter apps (iOS, Android, web): next.

Design and protocol: [`docs/DESIGN.md`](docs/DESIGN.md).

## License
MIT — see [LICENSE](LICENSE).
