import 'dart:typed_data';

import 'errors.dart';
import 'json.dart';

/// From [since] on, the dog's position is the one shared by member [memberId].
class RunSource {
  const RunSource(this.memberId, this.since);

  final String memberId;
  final DateTime since;
}

enum RunStatus { planned, running, finished }

/// A dog working a track (`run` collection, written by the owner and editors).
///
/// The dog carries no phone: its position is the one shared by a member the
/// project leader designates — the handler's official follower, or a bot
/// feeding a GPS collar. The designated member can change during the run;
/// [sources] keeps every change so the dog's path can be put back together.
class Run {
  Run({
    required this.track,
    required this.dog,
    this.handler,
    List<RunSource> sources = const [],
    this.started,
    this.finished,
    this.extra = const {},
  }) : sources = List.unmodifiable(sources);

  factory Run.fromJson(Json j) {
    j.checkVersion(version);
    final src = j.opt<List<dynamic>>('src') ?? const [];
    return Run(
      track: j.req<String>('track'),
      dog: j.req<String>('dog'),
      handler: j.opt<String>('handler'),
      sources: [
        for (final s in src)
          if (s is Map<String, dynamic>)
            RunSource(s.req<String>('m'), msToDate(s.req<int>('t')))
          else
            throw const ContentFormatException('field "src" must hold objects'),
      ],
      started: _optTime(j, 'start'),
      finished: _optTime(j, 'end'),
      extra: Map.unmodifiable(j.optMap('extra')),
    );
  }

  factory Run.decode(Uint8List b) => Run.fromJson(decodeJson(b));

  static const version = 1;

  /// Id of the track (in the `track` collection).
  final String track;

  /// Name of the dog.
  final String dog;

  /// Name of the handler.
  final String? handler;

  /// Designated position sources, in time order.
  final List<RunSource> sources;

  final DateTime? started, finished;

  /// Fields unknown to this version, preserved on round trip.
  final Json extra;

  /// The member currently sharing the dog's position.
  String? get source => sources.isEmpty ? null : sources.last.memberId;

  RunStatus get status => finished != null
      ? RunStatus.finished
      : started != null
      ? RunStatus.running
      : RunStatus.planned;

  /// The member sharing the dog's position at [time].
  String? sourceAt(DateTime time) {
    String? m;
    for (final s in sources) {
      if (s.since.isAfter(time)) break;
      m = s.memberId;
    }
    return m;
  }

  /// Who shared the dog's position when: (member, from, until — null = still).
  List<(String, DateTime, DateTime?)> get sourceIntervals => [
    for (var i = 0; i < sources.length; i++)
      (sources[i].memberId, sources[i].since, i + 1 < sources.length ? sources[i + 1].since : finished),
  ];

  /// [memberId] shares the dog's position from [at] on.
  Run withSource(String memberId, DateTime at) =>
      source == memberId ? this : _copy(sources: [...sources, RunSource(memberId, at)]);

  Run start(DateTime at) => _copy(started: at);

  Run finish(DateTime at) => _copy(finished: at);

  Run copyWith({String? track, String? dog, String? handler, Json? extra}) =>
      _copy(track: track, dog: dog, handler: handler, extra: extra);

  Run _copy({
    String? track,
    String? dog,
    String? handler,
    List<RunSource>? sources,
    DateTime? started,
    DateTime? finished,
    Json? extra,
  }) => Run(
    track: track ?? this.track,
    dog: dog ?? this.dog,
    handler: handler ?? this.handler,
    sources: sources ?? this.sources,
    started: started ?? this.started,
    finished: finished ?? this.finished,
    extra: extra ?? this.extra,
  );

  Json toJson() => {
    'v': version,
    'track': track,
    'dog': dog,
    if (handler != null) 'handler': handler,
    if (sources.isNotEmpty)
      'src': [
        for (final s in sources) {'m': s.memberId, 't': s.since.millisecondsSinceEpoch},
      ],
    if (started != null) 'start': started!.millisecondsSinceEpoch,
    if (finished != null) 'end': finished!.millisecondsSinceEpoch,
    if (extra.isNotEmpty) 'extra': extra,
  };

  Uint8List encode() => encodeJson(toJson());

  static DateTime? _optTime(Json j, String k) {
    final v = j.opt<int>(k);
    return v == null ? null : msToDate(v);
  }
}
