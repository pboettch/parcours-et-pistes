import 'dart:async';
import 'dart:typed_data';

import 'package:pep_channel/pep_channel.dart' as ch;
import 'package:pep_channel/pep_channel.dart' hide MessageRejected;
import 'package:pep_content/pep_content.dart' hide utf8Bytes;

import 'collections.dart';
import 'project.dart';
import 'session_events.dart';
import 'track.dart';

/// When a session records its own positions into its path (see
/// [ProjectSession.publishPosition]).
enum PathMode {
  never,

  /// While this member is the designated position source of an unfinished
  /// run (the default): the dog's path is kept for everyone.
  whenSource,
  always,
}

/// A Parcours et Pistes project on one device: the content model
/// (`pep_content`) mapped onto a [SecureChannel] (`pep_channel`), see
/// [PepCollections].
///
/// All security (encryption, signatures, access rules and assignments,
/// revisions, expiry) is the channel's job; this class only encodes and decodes
/// content. Items of collections it does not know (content types added by
/// newer app versions) are ignored.
class ProjectSession {
  ProjectSession._(this.channel, this.deviceId, DateTime Function()? clock, Duration? pathInterval)
    : _clock = clock ?? DateTime.now,
      pathInterval = pathInterval ?? defaultPathInterval {
    _sub = channel.events.listen(_onChannelEvent);
    _loadRecorded();
    if (pathInterval != null) _pathTimer = Timer.periodic(pathInterval, (_) => _flushInBackground());
  }

  /// Creates a new project owned by [identity].
  static Future<ProjectSession> create({
    required PepCrypto crypto,
    required Transport transport,
    required Identity identity,
    required String name,
    required Discipline discipline,
    required String password,
    String? description,
    Duration positionTtl = PepCollections.defaultPositionTtl,
    String topicBase = ChannelTopics.defaultBase,
    String? linkBroker,
    KdfParams? kdf,
    DateTime Function()? clock,
    Duration pruneInterval = const Duration(seconds: 15),
    String? deviceId,
    Duration? pathInterval = defaultPathInterval,
  }) async {
    _checkDeviceId(deviceId);
    final channel = await SecureChannel.create(
      crypto: crypto,
      transport: transport,
      identity: identity,
      password: password,
      collections: PepCollections.defaults(positionTtl: positionTtl),
      topicBase: topicBase,
      linkBroker: linkBroker,
      kdf: kdf,
      clock: clock,
      pruneInterval: pruneInterval,
    );
    try {
      await channel.put(
        PepCollections.info,
        PepCollections.infoId,
        ProjectInfo(name: name, description: description, discipline: discipline).encode(),
      );
    } catch (_) {
      await channel.close(clearEphemeral: false);
      rethrow;
    }
    return _open(channel, deviceId, clock, pathInterval);
  }

  /// The session over [channel]; closes the channel if that fails.
  static Future<ProjectSession> _open(
    SecureChannel channel,
    String? deviceId,
    DateTime Function()? clock,
    Duration? pathInterval,
  ) async {
    final ProjectSession s;
    try {
      s = ProjectSession._(channel, deviceId, clock, pathInterval);
    } catch (_) {
      await channel.close(clearEphemeral: false);
      rethrow;
    }
    try {
      if (s._projectOrNull == null) throw const ChannelNotFoundException('no valid project information in the channel');
      if (s.isOwner) await s.ensureCollections();
    } catch (_) {
      await s.close(clearPosition: false);
      rethrow;
    }
    return s;
  }

  static final _deviceIdRe = RegExp(r'^[A-Za-z0-9_-]{1,32}$');

  static void _checkDeviceId(String? id) {
    if (id != null && !_deviceIdRe.hasMatch(id)) throw ArgumentError.value(id, 'deviceId', 'not [A-Za-z0-9_-]{1,32}');
  }

  /// Joins an existing project from its invitation [link] and [password].
  /// Returns with the complete project state (all tracks included).
  ///
  /// Throws [WrongPasswordException], or [ChannelNotFoundException] when no
  /// project signed by the owner named in the link is found.
  ///
  /// The owner's session adds collections introduced by newer versions to the
  /// project ([ensureCollections]).
  static Future<ProjectSession> join({
    required PepCrypto crypto,
    required Transport transport,
    required Identity identity,
    required JoinLink link,
    required String password,
    Duration timeout = const Duration(seconds: 10),
    DateTime Function()? clock,
    Duration pruneInterval = const Duration(seconds: 15),
    String? deviceId,
    Duration? pathInterval = defaultPathInterval,
  }) async {
    _checkDeviceId(deviceId);
    final channel = await SecureChannel.join(
      crypto: crypto,
      transport: transport,
      identity: identity,
      link: link,
      password: password,
      timeout: timeout,
      clock: clock,
      pruneInterval: pruneInterval,
    );
    return _open(channel, deviceId, clock, pathInterval);
  }

  /// The underlying secure channel (for advanced use and tests).
  final SecureChannel channel;

  /// This installation's device id (stable, app-generated, `[A-Za-z0-9_-]{1,32}`;
  /// topics only carry a keyed hash of it), so that several devices of one
  /// user share positions and record paths side by side. Null: one per member
  /// — then only one device of the member may record (two would overwrite each
  /// other's path).
  final String? deviceId;

  /// How often a recording session republishes its full track by default.
  static const defaultPathInterval = Duration(seconds: 30);

  /// How often this session republishes its full track while it records.
  /// Created with a null interval, the session has no timer: points go out
  /// with later positions, [flushPath] and [close].
  final Duration pathInterval;

  /// Positions less accurate than this (m) are not recorded into the path.
  static const pathMaxAccuracy = 50.0;

  /// When this session records its positions into its path.
  PathMode pathMode = PathMode.whenSource;

  final DateTime Function() _clock;
  Timer? _pathTimer;

  /// This device's full recorded track: the closed segments, and the current
  /// one by time in ms (null until the device records).
  final _segments = <List<TimedPoint>>[];
  Map<int, TimedPoint>? _recorded;

  /// Closed segments not published yet.
  final _unpublished = <int>{};

  /// Points recorded in the current segment since it was last published.
  var _pathDirty = false;
  Future<bool>? _flushing;
  DateTime? _pathPublished;

  /// Next rolling item to use.
  var _nextSlot = 0;

  /// Member id by self item id (pseudonym), to name removed items.
  final _selfOwners = <String, String>{};

  late final StreamSubscription<ch.ChannelEvent> _sub;
  final _events = StreamController<SessionEvent>.broadcast();

  /// Decoded content by item topic: (the item decoded, value or null if invalid).
  final _decoded = <String, (ChannelItem, Object?)>{};

  // ---------------------------------------------------------------- state

  String get projectId => channel.channelId;
  String get memberId => channel.memberId;
  String get ownerId => channel.ownerId;
  bool get isOwner => channel.isOwner;

  /// Who may change track [trackId]: the member the project owner assigned it
  /// to, else the project owner.
  String trackOwner(String trackId) => channel.acl.assigneeOf(PepCollections.track, trackId) ?? ownerId;

  /// Whether this member may change track [trackId] (see [trackOwner]).
  bool canEditTrack(String trackId) => trackOwner(trackId) == memberId;

  /// A new track id, e.g. to assign a track before its owner publishes it.
  String newTrackId() => channel.generateItemId();

  JoinLink get joinLink => channel.joinLink;

  Stream<SessionEvent> get events => _events.stream;

  Project get project => _projectOrNull ?? (throw StateError('project information not available'));

  Project? get _projectOrNull {
    final i = channel.item(PepCollections.info, PepCollections.infoId);
    final info = i == null ? null : _decode(i, ProjectInfo.decode);
    return info == null ? null : Project(info, channel.acl, rev: i!.rev, updated: i.time);
  }

  /// Tracks by id (tracks with invalid GPX are left out).
  Map<String, Track> get tracks => _all(PepCollections.track, _track);

  /// Member profiles by member id.
  Map<String, MemberProfile> get members => _bySigner(PepCollections.member, MemberProfile.decode);

  /// Fresh positions by member id (the most recent one when a member shares
  /// from several devices).
  Map<String, Position> get positions => _bySigner(PepCollections.position, Position.decode);

  /// Runs by id.
  Map<String, Run> get runs => _all(PepCollections.run, (i) => _decode(i, Run.decode));

  /// Whether this session currently records its positions (see [pathMode]).
  bool get recordingPath => switch (pathMode) {
    PathMode.never => false,
    PathMode.always => true,
    PathMode.whenSource => runs.values.any((r) => r.status != RunStatus.finished && r.source == memberId),
  };

  /// Whether recorded points have not been published in the full track yet
  /// (see [flushPath]).
  bool get pathPending => _pathDirty || _unpublished.isNotEmpty;

  /// The recorded path of [memberId] (all devices): full tracks and rolling
  /// points, in time order.
  List<TimedPoint> path(String memberId) {
    final byMs = <int, TimedPoint>{};
    for (final i in channel.items(PepCollections.path).values) {
      if (i.signerId != memberId) continue;
      for (final p in _decode(i, RecordedPath.decode)?.points ?? const <TimedPoint>[]) {
        byMs[p.time.millisecondsSinceEpoch] = p;
      }
    }
    for (final i in channel.items(PepCollections.pathPoint).values) {
      if (i.signerId != memberId) continue;
      if (_decode(i, _pathPoint) case final p?) byMs[p.time.millisecondsSinceEpoch] = p;
    }
    return byMs.values.toList()..sort((a, b) => a.time.compareTo(b.time));
  }

  /// The path of the dog of run [runId]: the recorded paths and live
  /// positions of its successive position sources, each over its period.
  List<TimedPoint> dogPath(String runId) {
    final run = runs[runId];
    if (run == null) return const [];
    final out = <TimedPoint>[];
    for (final (member, from, until) in run.sourceIntervals) {
      bool within(DateTime t) => !t.isBefore(from) && (until == null || t.isBefore(until));
      final part = path(member).where((p) => within(p.time)).toList();
      final live = positions[member];
      if (live != null && within(live.time) && (part.isEmpty || live.time.isAfter(part.last.time))) {
        part.add(TimedPoint(live.lat, live.lon, live.time));
      }
      out.addAll(part);
    }
    return out..sort((a, b) => a.time.compareTo(b.time));
  }

  /// How far the dog of run [runId] has come along its track; null when the
  /// run or its track is unknown.
  TrailProgress? runProgress(String runId, {ProgressParams params = const ProgressParams()}) {
    final run = runs[runId];
    final points = run == null ? null : tracks[run.track]?.document.tracks.expand((t) => t.points).toList();
    if (points == null || points.isEmpty) return null;
    return TrailProgress.match(TrackLine(points), dogPath(runId), params: params);
  }

  // -------------------------------------------------------------- actions

  /// Publishes a new track (project owner), or a new revision of track [id]
  /// (its owner, see [trackOwner]). Everything about the track (name, objects,
  /// custom sections) is in the [gpx] document.
  ///
  /// With [visibleTo] (member ids), only those members — plus the project
  /// owner and the publisher — can see the track. Without it, a new track is
  /// visible to every member and an update keeps the track's visibility;
  /// [everyone] makes it visible to every member.
  Future<Track> publishTrack({String? id, required String gpx, Set<String>? visibleTo, bool everyone = false}) async {
    if (everyone && visibleTo != null) throw ArgumentError('visibleTo and everyone exclude each other');
    final parsed = Gpx.parse(gpx); // reject invalid GPX before publishing
    final tid = id ?? newTrackId();
    _requireTrackOwner(tid);
    final recipients = everyone ? null : visibleTo ?? channel.recipientsOf(PepCollections.track, tid);
    final item = await channel.put(PepCollections.track, tid, utf8Bytes(gpx), recipients: recipients);
    return Track(item, parsed: parsed);
  }

  /// Deletes track [id] (its owner).
  Future<void> deleteTrack(String id) async {
    _requireTrackOwner(id);
    await channel.delete(PepCollections.track, id);
  }

  /// Project owner only: makes [memberId] the owner of track [trackId] (null:
  /// the project owner again), who is then the only one to change it. The
  /// track may not exist yet (see [newTrackId]).
  Future<void> assignTrack(String trackId, String? memberId) => channel.assign(PepCollections.track, trackId, memberId);

  /// Owner only: updates name, description and/or the position TTL.
  Future<void> updateProject({String? name, String? description, Duration? positionTtl}) async {
    if (!isOwner) throw const AuthorizationException('only the project owner can do this');
    if (name != null || description != null) {
      final info = project.info.copyWith(name: name, description: description);
      await channel.put(PepCollections.info, PepCollections.infoId, info.encode());
    }
    if (positionTtl != null) {
      final collections = {...channel.acl.collections};
      collections[PepCollections.position] =
          (collections[PepCollections.position] ?? const CollectionPolicy(Writers.self)).withTtl(positionTtl);
      await channel.updateAcl(collections: collections);
    }
  }

  /// Shares this device's position and, when [recordingPath], records it into
  /// this device's path: on the next rolling item ([PepCollections.pathPoint])
  /// and, every [pathInterval], in the full track ([PepCollections.path]).
  /// Recorded points that cannot be published (no connection) stay in the
  /// full track and go out with its next publication.
  Future<void> publishPosition(Position position) async {
    int? slot;
    if (recordingPath && (position.accuracy ?? 0) <= pathMaxAccuracy) {
      var current = _recorded ??= {};
      if (current.length >= PepCollections.pathSegmentPoints) {
        _unpublished.add(_segments.length);
        _segments.add(RecordedPath(current.values).points);
        current = _recorded = {};
      }
      current[position.time.millisecondsSinceEpoch] = TimedPoint(position.lat, position.lon, position.time);
      _pathDirty = true;
      slot = _nextSlot;
      _nextSlot = (slot + 1) % PepCollections.rollingPoints;
    }
    await channel.put(PepCollections.position, channel.selfItemId(device: deviceId), position.encode());
    if (slot == null) return;
    try {
      await channel.put(PepCollections.pathPoint, _rollingId(slot), position.encode());
    } on TransportException {
      // in the full track later
    }
    final last = _pathPublished;
    if (last == null || !_now().isBefore(last.add(pathInterval))) await flushPath();
  }

  /// Publishes this device's full track if points were recorded since it was
  /// last published (also done every [pathInterval] and on [close]); waits
  /// for a publication already running. Returns false if some points are
  /// still unpublished (no connection).
  Future<bool> flushPath() async {
    final running = _flushing;
    if (running != null) await running;
    if (!pathPending) return true;
    if (_flushing != null) return flushPath(); // another caller started one meanwhile
    final f = _flushing = _publishRecorded();
    try {
      return await f;
    } finally {
      _flushing = null;
    }
  }

  Future<bool> _publishRecorded() async {
    _pathDirty = false;
    try {
      for (final seg in _unpublished.toList()..sort()) {
        await channel.put(PepCollections.path, _segmentId(seg), RecordedPath(_segments[seg]).encode());
        _unpublished.remove(seg);
      }
      final current = _recorded;
      if (current != null && current.isNotEmpty) {
        await channel.put(PepCollections.path, _segmentId(_segments.length), RecordedPath(current.values).encode());
      }
      _pathPublished = _now();
      return !pathPending;
    } on TransportException {
      _pathDirty = true;
      return false;
    } catch (_) {
      _pathDirty = true;
      rethrow;
    }
  }

  Future<void> clearPosition() => channel.delete(PepCollections.position, channel.selfItemId(device: deviceId));

  /// Publishes this member's profile; [bot] marks an automated member (e.g. a
  /// service feeding a GPS collar).
  Future<void> setMemberName(String name, {bool bot = false}) async {
    await channel.put(PepCollections.member, channel.selfItemId(), MemberProfile(name: name, bot: bot).encode());
  }

  /// Creates run [id] (default: a new id) or replaces it; returns its id.
  /// Project owner only, like the other run changes.
  Future<String> putRun(Run run, {String? id}) async {
    final rid = id ?? channel.generateItemId();
    await channel.put(PepCollections.run, rid, run.encode());
    return rid;
  }

  Future<void> deleteRun(String id) => channel.delete(PepCollections.run, id);

  /// Designates [memberId] as the one sharing the dog's position in run
  /// [runId], from now on.
  Future<void> setRunSource(String runId, String memberId) {
    publicKeyFromId(memberId);
    return _updateRun(runId, (r) => r.withSource(memberId, _now()));
  }

  Future<void> startRun(String runId) => _updateRun(runId, (r) => r.start(_now()));

  Future<void> finishRun(String runId) => _updateRun(runId, (r) => r.finish(_now()));

  /// Owner only: adds the collections of this version missing from a project
  /// created by an older one.
  Future<void> ensureCollections() async {
    if (!isOwner) throw const AuthorizationException('only the project owner can do this');
    final current = channel.acl.collections;
    final missing = {
      for (final e in PepCollections.defaults().entries)
        if (!current.containsKey(e.key)) e.key: e.value,
    };
    if (missing.isNotEmpty) await channel.updateAcl(collections: {...current, ...missing});
  }

  Future<void> sync({Duration timeout = const Duration(seconds: 10)}) => channel.sync(timeout: timeout);

  void prunePositions() => channel.prune();

  /// Owner only: removes the project from the broker and closes the session
  /// (if it fails, e.g. offline, the session stays open: retry or [close]).
  Future<void> deleteProject() async {
    if (!isOwner) throw const AuthorizationException('only the project owner can do this');
    await _flushing?.then((_) {}, onError: (Object _) {});
    await channel.deleteChannel(); // if it fails, the session goes on as before
    _pathTimer?.cancel();
    _recorded = null;
    _segments.clear();
    _unpublished.clear();
    _pathDirty = false;
    await _shutdown();
  }

  /// Stops syncing; by default clears the position shared by this session.
  /// Publishes the recorded points not published yet first, if possible.
  Future<void> close({bool clearPosition = true}) async {
    _pathTimer?.cancel();
    try {
      await flushPath();
    } on PepException {
      // what could not be published stays unpublished
    } on StateError {
      // closed meanwhile
    } finally {
      try {
        await channel.close(clearEphemeral: clearPosition);
      } finally {
        await _shutdown();
      }
    }
  }

  // ------------------------------------------------------------ internals

  DateTime _now() => _clock().toUtc();

  Future<void> _updateRun(String runId, Run Function(Run) change) async {
    final run = runs[runId];
    if (run == null) throw ArgumentError.value(runId, 'runId', 'unknown run');
    await putRun(change(run), id: runId);
  }

  void _flushInBackground() => unawaited(flushPath().then((_) {}, onError: (Object _) {}));

  void _requireTrackOwner(String trackId) {
    if (trackOwner(trackId) != memberId) {
      throw AuthorizationException('track $trackId belongs to ${trackOwner(trackId)}');
    }
  }

  /// Rolling item [slot] of this device.
  String _rollingId(int slot) => channel.selfItemId(device: 'r$slot${deviceId == null ? '' : '-$deviceId'}');

  /// Segment [n] of this device's full track.
  String _segmentId(int n) => channel.selfItemId(device: 'f$n${deviceId == null ? '' : '-$deviceId'}');

  /// Loads what this device recorded before (e.g. an earlier run of the app):
  /// its full track segments, and the rolling points after them (published
  /// with the next full track); the rolling item to use next follows the most
  /// recent point.
  void _loadRecorded() {
    final declared = channel.acl.collections;
    if (!declared.containsKey(PepCollections.path) || !declared.containsKey(PepCollections.pathPoint)) return;
    var lastValid = false;
    for (var n = 0; ; n++) {
      final i = channel.item(PepCollections.path, _segmentId(n));
      if (i == null || i.signerId != memberId) break;
      final points = _decode(i, RecordedPath.decode)?.points;
      // A segment this version cannot read (e.g. from a newer one) stays as it
      // is: closed, never overwritten.
      _segments.add(points ?? const []);
      lastValid = points != null;
    }
    if (lastValid && _segments.last.length < PepCollections.pathSegmentPoints) {
      _recorded = {for (final p in _segments.removeLast()) p.time.millisecondsSinceEpoch: p};
    }
    final newestSaved = _recorded?.values.lastOrNull?.time ?? _segments.lastOrNull?.lastOrNull?.time;
    DateTime? newest;
    for (var slot = 0; slot < PepCollections.rollingPoints; slot++) {
      final i = channel.item(PepCollections.pathPoint, _rollingId(slot));
      final p = i == null || i.signerId != memberId ? null : _decode(i, _pathPoint);
      if (p == null) continue;
      if (newest == null || p.time.isAfter(newest)) {
        newest = p.time;
        _nextSlot = (slot + 1) % PepCollections.rollingPoints;
      }
      if (newestSaved == null || p.time.isAfter(newestSaved)) {
        (_recorded ??= {})[p.time.millisecondsSinceEpoch] = p;
        _pathDirty = true;
      }
    }
    if (_recorded == null && _segments.isNotEmpty) _recorded = {};
  }

  static TimedPoint _pathPoint(Uint8List body) {
    final p = Position.decode(body);
    return TimedPoint(p.lat, p.lon, p.time);
  }

  Future<void> _shutdown() async {
    _pathTimer?.cancel();
    await _sub.cancel();
    if (!_events.isClosed) unawaited(_events.close()); // not awaited: see SecureChannel.close
  }

  void _emit(SessionEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  /// Items of a `self` collection by member id (latest publish time wins).
  Map<String, T> _bySigner<T>(String collection, T Function(Uint8List) decode) {
    final latest = <String, ChannelItem>{};
    for (final i in channel.items(collection).values) {
      if (_decode(i, decode) == null) continue;
      final cur = latest[i.signerId];
      if (cur == null || i.time.isAfter(cur.time)) latest[i.signerId] = i;
    }
    return Map.unmodifiable({for (final e in latest.entries) e.key: _decode(e.value, decode) as T});
  }

  Map<String, T> _all<T>(String collection, T? Function(ChannelItem) decode) =>
      Map.unmodifiable({for (final i in channel.items(collection).values) i.id: ?decode(i)});

  /// Decodes each accepted version of an item once; invalid content yields null.
  T? _decode<T>(ChannelItem i, T Function(Uint8List) decode) {
    final key = '${i.collection}/${i.id}';
    final cached = _decoded[key];
    if (cached != null && identical(cached.$1, i)) return cached.$2 as T?;
    T? value;
    try {
      value = decode(i.body);
    } on ContentFormatException {
      value = null;
    } on FormatException {
      value = null; // e.g. invalid UTF-8
    } on ArgumentError {
      value = null; // e.g. a value out of range
    }
    _decoded[key] = (i, value);
    return value;
  }

  Track? _track(ChannelItem i) => _decode(i, (b) {
    final t = Track(i);
    t.document; // validate the GPX
    return t;
  });

  void _onChannelEvent(ch.ChannelEvent e) {
    switch (e) {
      case ch.AclUpdated():
        if (_projectOrNull case final p?) _emit(ProjectUpdated(p));
      case ch.ItemUpdated(:final item):
        _onItem(item);
      case ch.ItemRemoved(:final collection, :final id):
        switch (collection) {
          case PepCollections.track:
            _emit(TrackRemoved(id));
          case PepCollections.member:
            if (_selfOwners[id] case final m?) _emit(MemberRemoved(m));
          case PepCollections.position:
            // Another device of the same member may still share a position.
            if (_selfOwners[id] case final m? when !positions.containsKey(m)) _emit(PositionRemoved(m));
          case PepCollections.run:
            _emit(RunRemoved(id));
          case PepCollections.pathPoint || PepCollections.path:
            if (_selfOwners[id] case final m?) _emit(PathUpdated(m));
        }
      case ch.ChannelDeleted():
        _emit(const ProjectDeleted());
      case ch.MessageRejected(:final topic, :final error):
        _emit(MessageRejected(topic, error));
    }
  }

  void _onItem(ChannelItem item) {
    final topic = channel.topics.item(item.collection, item.id);
    if (const {
      PepCollections.member,
      PepCollections.position,
      PepCollections.pathPoint,
      PepCollections.path,
    }.contains(item.collection)) {
      _selfOwners[item.id] = item.signerId;
    }
    SessionEvent? event;
    switch (item.collection) {
      case PepCollections.info:
        final p = _projectOrNull;
        if (p != null) event = ProjectUpdated(p);
      case PepCollections.track:
        final t = _track(item);
        if (t != null) event = TrackUpdated(t);
      case PepCollections.member:
        final m = _decode(item, MemberProfile.decode);
        if (m != null) event = MemberUpdated(item.signerId, m);
      case PepCollections.position:
        final p = _decode(item, Position.decode);
        if (p != null) event = PositionUpdated(item.signerId, p);
      case PepCollections.run:
        final r = _decode(item, Run.decode);
        if (r != null) event = RunUpdated(item.id, r);
        // No longer recording: publish the last points now.
        if (_pathDirty && !recordingPath) _flushInBackground();
      case PepCollections.pathPoint:
        if (_decode(item, _pathPoint) != null) event = PathUpdated(item.signerId);
      case PepCollections.path:
        if (_decode(item, RecordedPath.decode) != null) event = PathUpdated(item.signerId);
      default:
        return; // content type unknown to this version: ignored
    }
    _emit(event ?? MessageRejected(topic, ContentFormatException('invalid ${item.collection} content')));
  }
}
