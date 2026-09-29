import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:pep_channel/pep_channel.dart' as ch;
import 'package:pep_channel/pep_channel.dart' hide PasswordChanged, MessageRejected;
import 'package:pep_content/pep_content.dart' hide utf8Bytes;

import 'collections.dart';
import 'project.dart';
import 'session_events.dart';
import 'trace_recorder.dart';
import 'track.dart';

/// When a session records its own positions into its path (`trace`).
enum TraceMode {
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
/// All security (encryption, signatures, access rules, revisions, expiry,
/// password changes) is the channel's job; this class only encodes and decodes
/// content. Items of collections it does not know (content types added by
/// newer app versions) are ignored.
class ProjectSession {
  ProjectSession._(this.channel, this.deviceId, DateTime Function()? clock, Duration traceFlushInterval)
    : _clock = clock ?? DateTime.now {
    _recorder = TraceRecorder(channel, deviceId: deviceId, flushInterval: traceFlushInterval);
    _sub = channel.events.listen(_onChannelEvent);
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
    Duration traceFlushInterval = defaultTraceFlushInterval,
  }) async {
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
    await channel.put(
      PepCollections.info,
      PepCollections.infoId,
      ProjectInfo(name: name, description: description, discipline: discipline).encode(),
    );
    return ProjectSession._(channel, deviceId, clock, traceFlushInterval);
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
    Duration traceFlushInterval = defaultTraceFlushInterval,
  }) async {
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
    final s = ProjectSession._(channel, deviceId, clock, traceFlushInterval);
    if (s._projectOrNull == null) {
      await s.close(clearPosition: false);
      throw const ChannelNotFoundException('no valid project information in the channel');
    }
    if (s.isOwner && !s.locked) await s.ensureCollections();
    return s;
  }

  /// The underlying secure channel (for advanced use and tests).
  final SecureChannel channel;

  /// This installation's device id (stable, app-generated, `[A-Za-z0-9_-]{1,32}`),
  /// so that several devices of one user share positions side by side. Null:
  /// one position per member.
  final String? deviceId;

  static const defaultTraceFlushInterval = Duration(seconds: 30);

  /// Positions less accurate than this (m) are not recorded into the path.
  static const traceMaxAccuracy = 50.0;

  /// When this session records its positions into its path.
  TraceMode traceMode = TraceMode.whenSource;

  final DateTime Function() _clock;
  late final TraceRecorder _recorder;

  /// Member id by self item id (pseudonym), to name removed items.
  final _selfOwners = <String, String>{};
  var _offerNotified = false;

  late final StreamSubscription<ch.ChannelEvent> _sub;
  final _events = StreamController<SessionEvent>.broadcast();

  /// Decoded content by item topic: (revision, value or null if invalid).
  final _decoded = <String, (int, Object?)>{};

  // ---------------------------------------------------------------- state

  String get projectId => channel.channelId;
  String get memberId => channel.memberId;
  String get ownerId => channel.ownerId;
  bool get isOwner => channel.isOwner;

  /// True after the owner changed the password, until [unlock] succeeds.
  bool get locked => channel.locked;

  bool get canEditTracks => channel.canWrite(PepCollections.track, '-');

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

  /// Whether this session currently records its positions (see [traceMode]).
  bool get recordingTrace => switch (traceMode) {
    TraceMode.never => false,
    TraceMode.always => true,
    TraceMode.whenSource => runs.values.any((r) => r.status != RunStatus.finished && r.source == memberId),
  };

  /// The recorded path of [memberId] (all devices), in time order.
  List<TimedPoint> trace(String memberId) {
    final out = <TimedPoint>[
      for (final i in channel.items(PepCollections.trace).values)
        if (i.signerId == memberId) ...?_decode(i, _tracePoints),
    ]..sort((a, b) => a.time.compareTo(b.time));
    return out;
  }

  /// The path of the dog of run [runId]: the recorded paths and live
  /// positions of its successive position sources, each over its period.
  List<TimedPoint> dogPath(String runId) {
    final run = runs[runId];
    if (run == null) return const [];
    final out = <TimedPoint>[];
    for (final (member, from, until) in run.sourceIntervals) {
      bool within(DateTime t) => !t.isBefore(from) && (until == null || t.isBefore(until));
      final part = trace(member).where((p) => within(p.time)).toList();
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

  /// Whether the owner offered the project ownership to this member.
  bool get ownershipOfferedToMe => channel.ownershipOfferedToMe;

  // -------------------------------------------------------------- actions

  /// Publishes a new track, or a new revision of track [id]. Everything about
  /// the track (name, objects, custom sections) is in the [gpx] document.
  ///
  /// With [visibleTo] (member ids), only those members — plus the owner and
  /// the publisher — can see the track; `null` = every member.
  Future<Track> publishTrack({String? id, required String gpx, Set<String>? visibleTo}) async {
    final parsed = Gpx.parse(gpx); // reject invalid GPX before publishing
    final item = await channel.put(
      PepCollections.track,
      id ?? channel.generateItemId(),
      utf8Bytes(gpx),
      recipients: visibleTo,
    );
    return Track(item, parsed: parsed);
  }

  Future<void> deleteTrack(String id) => channel.delete(PepCollections.track, id);

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

  Future<void> addEditor(String memberId) => channel.addEditor(memberId);

  Future<void> removeEditor(String memberId) => channel.removeEditor(memberId);

  /// Owner only: offers the project ownership to [memberId] (who must accept).
  Future<void> offerOwnership(String memberId) => channel.offerOwnership(memberId);

  Future<void> cancelOwnershipOffer() => channel.cancelOwnershipOffer();

  /// Takes over the ownership offered to this member (see [OwnershipOffered]);
  /// the former owner becomes an editor.
  Future<void> acceptOwnership() => channel.acceptOwnership();

  /// Shares this device's position, and records it into this member's path
  /// when [recordingTrace].
  Future<void> publishPosition(Position position) async {
    await channel.put(PepCollections.position, channel.selfItemId(device: deviceId), position.encode());
    if (recordingTrace && (position.accuracy ?? 0) <= traceMaxAccuracy) await _recorder.add(position);
  }

  Future<void> clearPosition() => channel.delete(PepCollections.position, channel.selfItemId(device: deviceId));

  /// Publishes this member's profile; [bot] marks an automated member (e.g. a
  /// service feeding a GPS collar).
  Future<void> setMemberName(String name, {bool bot = false}) async {
    await channel.put(PepCollections.member, channel.selfItemId(), MemberProfile(name: name, bot: bot).encode());
  }

  /// Creates run [id] (default: a new id) or replaces it; returns its id.
  /// Owner and editors.
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

  /// Publishes the positions recorded but not yet published.
  Future<void> flushTrace() => _recorder.flush();

  /// Owner only; see [SecureChannel.changePassword].
  Future<void> changePassword(String newPassword, {KdfParams? kdf}) => channel.changePassword(newPassword, kdf: kdf);

  Future<void> unlock(String password) => channel.unlock(password);

  Future<void> sync({Duration timeout = const Duration(seconds: 10)}) => channel.sync(timeout: timeout);

  void prunePositions() => channel.prune();

  /// Owner only: removes the project from the broker and closes the session.
  Future<void> deleteProject() async {
    _recorder.cancel();
    await channel.deleteChannel();
    await _shutdown();
  }

  /// Stops syncing; by default clears the position shared by this session.
  Future<void> close({bool clearPosition = true}) async {
    try {
      await _recorder.flush();
    } on PepException {
      _recorder.cancel(); // e.g. locked: keeps what was published
    }
    await channel.close(clearEphemeral: clearPosition);
    await _shutdown();
  }

  // ------------------------------------------------------------ internals

  DateTime _now() => _clock().toUtc();

  Future<void> _updateRun(String runId, Run Function(Run) change) async {
    final run = runs[runId];
    if (run == null) throw ArgumentError.value(runId, 'runId', 'unknown run');
    await putRun(change(run), id: runId);
  }

  static List<TimedPoint> _tracePoints(Uint8List body) => [
    for (final p in Gpx.parse(utf8.decode(body)).tracks.expand((t) => t.points))
      if (p.time != null) TimedPoint(p.lat, p.lon, p.time!),
  ];

  Future<void> _shutdown() async {
    await _sub.cancel();
    if (!_events.isClosed) await _events.close();
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

  /// Decodes [i] once per revision; invalid content yields null.
  T? _decode<T>(ChannelItem i, T Function(Uint8List) decode) {
    final key = '${i.collection}/${i.id}';
    final cached = _decoded[key];
    if (cached != null && cached.$1 == i.rev) return cached.$2 as T?;
    T? value;
    try {
      value = decode(i.body);
    } on ContentFormatException {
      value = null;
    } on FormatException {
      value = null; // e.g. invalid UTF-8
    }
    _decoded[key] = (i.rev, value);
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
        final offered = channel.ownershipOfferedToMe;
        if (offered && !_offerNotified) _emit(OwnershipOffered(channel.ownerId));
        _offerNotified = offered;
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
          case PepCollections.trace:
            if (_selfOwners[id] case final m?) _emit(TraceUpdated(m));
        }
      case ch.PasswordChanged():
        _emit(const PasswordChanged());
      case ch.ChannelDeleted():
        _emit(const ProjectDeleted());
      case ch.MessageRejected(:final topic, :final error):
        _emit(MessageRejected(topic, error));
    }
  }

  void _onItem(ChannelItem item) {
    final topic = channel.topics.item(item.collection, item.id);
    if (const {PepCollections.member, PepCollections.position, PepCollections.trace}.contains(item.collection)) {
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
      case PepCollections.trace:
        if (_decode(item, _tracePoints) != null) event = TraceUpdated(item.signerId);
      default:
        return; // content type unknown to this version: ignored
    }
    _emit(event ?? MessageRejected(topic, ContentFormatException('invalid ${item.collection} content')));
  }
}
