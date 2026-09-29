# pep_core

Shared low-level library of **Parcours et Pistes**: end-to-end encrypted sharing of search-dog
trails (GPX) and live positions over MQTT 5. Pure Dart — runs on the Dart VM, in Flutter apps
(iOS, Android, desktop) and in browsers.

Protocol and security design: [`docs/DESIGN.md`](../../docs/DESIGN.md).
A runnable version of the example below: [`example/example.dart`](example/example.dart).

## Usage

```dart
import 'package:pep_core/pep_core.dart';

final crypto = await PepCrypto.init();          // Flutter: PepCrypto(await SodiumSumoInit.init()) from sodium_libs
final me = Identity.generate(crypto);           // persist me.exportSeed() in secure storage
final transport = Mqtt5Transport(BrokerConfig(Uri.parse('wss://broker.example.org/mqtt')));

// Owner
final project = await ProjectSession.create(
  crypto: crypto, transport: transport, identity: me,
  name: 'Forêt de Chambaran', discipline: Discipline.ru, password: 'secret',
);
await project.publishTrack(gpx: gpxString); // name, objects, custom sections: all in the GPX
final link = project.joinLink.toUri();          // share link and password separately

// Participant
final session = await ProjectSession.join(
  crypto: crypto, transport: transport, identity: me,
  link: JoinLink.parse(link), password: 'secret',
);
session.events.listen((e) {
  switch (e) {
    case TrackUpdated(:final track):
      print('track ${track.name}');
    case PositionUpdated(:final memberId, :final position):
      print('$memberId at ${position.lat},${position.lon}');
    case PasswordChanged():
      print('ask for the new password, then session.unlock(pw)');
    default:
  }
});
await session.publishPosition(Position(lat: 45.2, lon: 5.3, time: DateTime.now()));
final objects = session.tracks.values.first.document.objects;   // RU objects = GPX waypoints
```

Main API: `ProjectSession` (`create`, `join`, `publishTrack`, `deleteTrack`, `addEditor`,
`removeEditor`, `updateProject`, `publishPosition`, `clearPosition`, `setMemberName`,
`changePassword`, `unlock`, `sync`, `deleteProject`, `close`; state getters `project`, `tracks`,
`members`, `positions`; `events` stream), `Gpx`, `JoinLink`, `Transport`.

### Web
Browsers need the sumo build of `sodium.js`: `dart run sodium:update_web --sumo` (Flutter web:
handled by `sodium_libs`). Only `ws://`/`wss://` brokers work in browsers.

## Development
From the repository root:

```bash
source .claude/scripts/env.sh          # user-local Flutter/Dart SDK
.claude/scripts/broker.sh start        # local mosquitto: mqtt :18883, ws :18080, mqtts :18884, wss :18443, auth :18885
.claude/scripts/test.sh                # all tests on the VM and in Chromium
.claude/scripts/test.sh -x broker      # without the broker integration tests
.claude/scripts/e2e.sh                 # end-to-end scenario with the CLI
```

CLI for manual testing: `dart run pep_core:pep --help`.

Status: 213 test runs (VM + Chromium; memory broker and mosquitto over TCP, TLS, WS, WSS),
~96 % line coverage (`dart test --coverage=coverage`, then `coverage:format_coverage`).
