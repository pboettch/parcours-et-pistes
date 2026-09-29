import 'dart:async';
import 'dart:math';

import 'package:pep_core/pep_core.dart';

import 'app_state.dart';

/// Development aid: a bot member walking the track of a run, so the live
/// features can be tried without anyone in the field. It joins the project as
/// its own member ("Chien simulé"); a leader designates it as the run's source.
class DogSimulator {
  DogSimulator._(this.runId, this._session, this._walker, this._rate);

  static Future<DogSimulator> start(AppState app, String runId, {double rate = 5}) async {
    final s = app.session!, p = app.current!;
    final run = s.runs[runId]!;
    final points = s.tracks[run.track]!.document.tracks.expand((t) => t.points).toList();
    final link = JoinLink.parse(p.link);
    final bot = await ProjectSession.join(
      crypto: app.crypto,
      transport: Mqtt5Transport(BrokerConfig(Uri.parse(link.broker ?? defaultBroker))),
      identity: app.storage.simulatorIdentity(app.crypto),
      link: link,
      password: p.password,
    );
    await bot.setMemberName('Chien simulé', bot: true);
    if (s.canEditTracks) {
      await s.setRunSource(runId, bot.memberId);
      if (run.status == RunStatus.planned) await s.startRun(runId);
    }
    final sim = DogSimulator._(runId, bot, TrailWalker(TrackLine(points)), rate);
    sim._timer = Timer.periodic(const Duration(seconds: 2), (_) => sim._step());
    unawaited(sim._step());
    return sim;
  }

  final String runId;
  final ProjectSession _session;
  final TrailWalker _walker;
  final double _rate;
  final _started = DateTime.now();
  final _random = Random();
  Timer? _timer;

  String get memberId => _session.memberId;

  Future<void> _step() async {
    final elapsed = DateTime.now().difference(_started) * _rate;
    final p = _walker.at(elapsed);
    try {
      await _session.publishPosition(
        Position(lat: p.lat, lon: p.lon, time: DateTime.now().toUtc(), accuracy: 3 + _random.nextDouble() * 5),
      );
    } on Exception {
      // next step
    }
    if (_walker.finishedAt(elapsed)) _timer?.cancel();
  }

  Future<void> stop() async {
    _timer?.cancel();
    await _session.close(clearPosition: false);
  }
}
