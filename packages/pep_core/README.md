# pep_core

Project sessions of **Parcours et Pistes** — the one package the apps import. `ProjectSession`
maps the content model ([`pep_content`](../pep_content)) onto the secure channel
([`pep_channel`](../pep_channel)): end-to-end encrypted sharing of search-dog trails (GPX),
live positions, runs and the dogs' recorded paths over MQTT 5. Pure Dart — Dart VM, Flutter
(iOS, Android, desktop) and browsers. It also re-exports both packages and contains the `pep`
CLI.

Protocol and security design: [`docs/DESIGN.md`](../../docs/DESIGN.md).
A runnable version of the example below: [`example/example.dart`](example/example.dart).

## Usage

```dart
import 'package:pep_core/pep_core.dart';

final crypto = await PepCrypto.init();          // Flutter: PepCrypto(await SodiumSumoInit.init()) from sodium_libs
final broker = BrokerConfig(Uri.parse('wss://broker.example.org/mqtt'));

// Owner, on their device
final owner = Identity.generate(crypto);        // persist owner.exportSeed() in secure storage
final project = await ProjectSession.create(
  crypto: crypto, transport: Mqtt5Transport(broker), identity: owner,
  name: 'Forêt de Chambaran', discipline: Discipline.ru, password: 'secret',
);
await project.publishTrack(gpx: gpxString); // name, objects, custom sections: all in the GPX
final link = project.joinLink.toUri();          // share link and password separately

// Participant, on another device (own identity, own transport)
final me = Identity.generate(crypto);
final session = await ProjectSession.join(
  crypto: crypto, transport: Mqtt5Transport(broker), identity: me,
  link: JoinLink.parse(link), password: 'secret',
);
session.events.listen((e) {
  switch (e) {
    case TrackUpdated(:final track):
      print('track ${track.name}');
    case PositionUpdated(:final memberId, :final position):
      print('$memberId at ${position.lat},${position.lon}');
    default:
  }
});
await session.publishPosition(Position(lat: 45.2, lon: 5.3, time: DateTime.now()));
final objects = session.tracks.values.first.document.objects;   // RU objects = GPX waypoints
```

One session per project per transport: two sessions of the same project need two transports.

## Main API
`ProjectSession`:
- **Lifecycle:** `create`, `join` (both take an optional `deviceId`, stable per installation),
  `sync`, `close`, `deleteProject` (owner), `ensureCollections` (owner; done on create/join).
- **Project:** `project`, `updateProject` (owner: name, description, position TTL), `joinLink`,
  `projectId`, `memberId`, `ownerId`, `isOwner`.
- **Tracks** (one owner each): `tracks`, `publishTrack` (`visibleTo` / `everyone` for per-track
  visibility), `deleteTrack`, `assignTrack` (owner), `newTrackId`, `trackOwner`, `canEditTrack`.
- **Members and positions:** `members`, `setMemberName` (`bot` for automated members),
  `positions`, `publishPosition`, `clearPosition`, `prunePositions`.
- **Runs:** `runs`, `dogPath(runId)`, `runProgress(runId)`; owner only: `putRun`, `deleteRun`,
  `setRunSource`, `startRun`, `finishRun`.
- **Path recording** (while this member is a run's source, by default): `pathMode`
  (`PathMode.whenSource`), `recordingPath`, `pathInterval`, `flushPath`, `pathPending`,
  `path(memberId)`.
- `events`: `ProjectUpdated`, `ProjectDeleted`, `TrackUpdated` / `TrackRemoved`,
  `MemberUpdated` / `MemberRemoved`, `PositionUpdated` / `PositionRemoved`, `RunUpdated` /
  `RunRemoved`, `PathUpdated`, `MessageRejected`; `channel` for low-level access. An empty
  project on the broker (`ProjectDeleted`) can also be vandalism: keep the local copy.

Also: `Project`, `Track` (`name`, `document`, `visibleTo`), `PepCollections` (content ↔
collection mapping), and the re-exported `pep_content` and `pep_channel` (`Gpx`, `JoinLink`,
`Transport`, …; the channel's own events are replaced by the session's).

### Web
Browsers need the sumo build of `sodium.js`: `dart run sodium:update_web --sumo` (Flutter web:
handled by `sodium_libs`). Only `ws://`/`wss://` brokers work in browsers.

## CLI
`dart run pep_core:pep --help` — a command-line client for manual testing (create, watch, push
tracks, share positions, runs, simulated dogs, …); `.claude/scripts/e2e.sh` runs every command
against the local dev broker. Development setup: see the
[repository README](../../README.md#development).
