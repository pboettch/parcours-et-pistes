import 'dart:async';
import 'dart:typed_data';

import '../codec/bytes.dart';
import '../crypto/envelope.dart';
import '../crypto/identity.dart';
import '../crypto/kdf.dart';
import '../crypto/pep_crypto.dart';
import '../errors.dart';
import '../model/gpx.dart';
import '../model/member.dart';
import '../model/meta.dart';
import '../model/position.dart';
import '../model/project_doc.dart';
import '../model/track_doc.dart';
import '../protocol/ids.dart';
import '../protocol/join_link.dart';
import '../protocol/topics.dart';
import '../transport/transport.dart';
import 'session_events.dart';

/// One project, seen from one device: keeps the decrypted, verified project
/// state in sync with the broker and publishes changes.
///
/// Every incoming message is decrypted, its signature verified and its signer
/// authorized (owner for the project document, owner/editors for tracks, the
/// member itself for member profiles and positions); anything else is dropped
/// and reported as [MessageRejected]. Documents carry revisions and older
/// revisions are ignored. The session's own publications are applied locally
/// right away and deduplicated when echoed back by the broker.
class ProjectSession {
  ProjectSession._({
    required PepCrypto crypto,
    required Transport transport,
    required Identity identity,
    required this.topics,
    required this.ownerId,
    required this.linkBroker,
    required DateTime Function()? clock,
    required Duration pruneInterval,
  })  : _c = crypto,
        _env = Envelope(crypto),
        _transport = transport,
        _me = identity,
        _ownerKey = publicKeyFromId(ownerId),
        _clock = clock ?? DateTime.now,
        _pruneInterval = pruneInterval;

  /// Creates a new project owned by [identity] and publishes it.
  static Future<ProjectSession> create({
    required PepCrypto crypto,
    required Transport transport,
    required Identity identity,
    required String name,
    required Discipline discipline,
    required String password,
    String? description,
    ProjectSettings settings = const ProjectSettings(),
    String topicBase = ProjectTopics.defaultBase,
    String? linkBroker,
    KdfParams? kdf,
    DateTime Function()? clock,
    Duration pruneInterval = const Duration(seconds: 15),
  }) async {
    await _ensureConnected(transport);
    final s = ProjectSession._(
      crypto: crypto,
      transport: transport,
      identity: identity,
      topics: ProjectTopics(newUuid(crypto), base: topicBase),
      ownerId: identity.id,
      linkBroker: linkBroker,
      clock: clock,
      pruneInterval: pruneInterval,
    );
    final params = kdf ?? KdfParams.generate(crypto);
    s._key = ProjectKey.derive(crypto, password, params);
    final meta = ProjectMeta(kdf: params, keyCheck: s._key!.check, rev: 1);
    await s._publishMeta(meta);
    await s._publishProject(ProjectDoc(
      id: s.projectId,
      name: name,
      description: description,
      discipline: discipline,
      ownerId: identity.id,
      settings: settings,
      rev: 1,
      updated: s._now(),
    ));
    await s._start();
    return s;
  }

  /// Joins an existing project from its invitation [link] and [password].
  ///
  /// Throws [WrongPasswordException] for a wrong password and
  /// [ProjectNotFoundException] when no metadata/project document signed by
  /// the owner named in the link arrives within [timeout].
  static Future<ProjectSession> join({
    required PepCrypto crypto,
    required Transport transport,
    required Identity identity,
    required JoinLink link,
    required String password,
    Duration timeout = const Duration(seconds: 10),
    DateTime Function()? clock,
    Duration pruneInterval = const Duration(seconds: 15),
  }) async {
    await _ensureConnected(transport);
    final s = ProjectSession._(
      crypto: crypto,
      transport: transport,
      identity: identity,
      topics: ProjectTopics(link.projectId, base: link.topicBase),
      ownerId: link.ownerId,
      linkBroker: link.broker,
      clock: clock,
      pruneInterval: pruneInterval,
    );
    try {
      await s._start();
      // After the barrier, all retained messages of the project have arrived,
      // so the session starts with the complete state (tracks included).
      await s.sync(timeout: timeout);
      await s._metaArrived.future.timeout(timeout,
          onTimeout: () => throw const ProjectNotFoundException('no project metadata on the broker'));
      await s.unlock(password);
      if (s._project == null) {
        await s._projectArrived.future.timeout(timeout,
            onTimeout: () => throw const ProjectNotFoundException('no valid project document on the broker'));
      }
      return s;
    } catch (_) {
      await s.close(clearPosition: false);
      rethrow;
    }
  }

  final PepCrypto _c;
  final Envelope _env;
  final Transport _transport;
  final Identity _me;
  final Uint8List _ownerKey;
  final DateTime Function() _clock;
  final Duration _pruneInterval;

  final ProjectTopics topics;

  /// Member id of the project owner (trust anchor from the join link).
  final String ownerId;

  /// Broker URL embedded in generated join links (null = app default broker).
  final String? linkBroker;

  ProjectKey? _key;
  ProjectMeta? _meta;
  ProjectDoc? _project;
  final _tracks = <String, TrackDoc>{};
  final _trackSigners = <String, String>{};
  final _trackRevs = <String, int>{};
  final _members = <String, MemberDoc>{};
  final _positions = <String, Position>{};

  /// Latest raw payload per topic (for dedup and re-processing after unlock).
  final _raw = <String, Uint8List>{};

  /// Track topics rejected for lack of permission; re-evaluated when the
  /// project document (editor list) changes.
  final _pendingAuth = <String>{};

  final _syncWaiters = <String, Completer<void>>{};
  final _metaArrived = Completer<void>();
  final _projectArrived = Completer<void>();
  final _events = StreamController<SessionEvent>.broadcast();
  StreamSubscription<TransportMessage>? _sub;
  Timer? _pruneTimer;
  var _closed = false;

  /// Whether this session shared a position that it has not cleared yet.
  var _sharingPosition = false;

  // ---------------------------------------------------------------- state

  String get projectId => topics.projectId;

  /// This device's member id.
  String get memberId => _me.id;

  Stream<SessionEvent> get events => _events.stream;

  ProjectDoc get project => _project ?? (throw StateError('project not loaded'));

  bool get isOwner => _me.id == ownerId;

  bool get canEditTracks => !locked && project.canEditTracks(_me.id);

  /// True after the owner changed the password, until [unlock] succeeds.
  bool get locked => _key == null;

  /// Live (non-deleted) tracks by id.
  Map<String, TrackDoc> get tracks => Map.unmodifiable(_tracks);

  /// Member who published the current revision of a track.
  String? trackSigner(String trackId) => _trackSigners[trackId];

  Map<String, MemberDoc> get members => Map.unmodifiable(_members);

  /// Fresh positions by member id (expired ones are filtered out).
  Map<String, Position> get positions {
    final ttl = project.settings.positionTtl;
    final now = _now();
    return Map.unmodifiable({
      for (final e in _positions.entries)
        if (e.value.isFresh(ttl, now: now)) e.key: e.value,
    });
  }

  JoinLink get joinLink =>
      JoinLink(projectId: projectId, ownerId: ownerId, broker: linkBroker, topicBase: topics.base);

  // -------------------------------------------------------------- actions

  /// Publishes a new track, or a new revision of track [id]. All track content
  /// (name, objects, custom sections) is part of the [gpx] document (see
  /// [Gpx.toXml]). Returns the published document.
  Future<TrackDoc> publishTrack({String? id, required String gpx}) async {
    _requireTrackEditor();
    Gpx.parse(gpx); // reject invalid GPX before publishing
    final tid = id ?? newTrackId(_c);
    final doc = TrackDoc(id: tid, rev: (_trackRevs[tid] ?? 0) + 1, updated: _now(), gpx: gpx);
    await _publishSealed(topics.track(tid), doc.encode());
    return doc;
  }

  /// Deletes a track by publishing a signed tombstone.
  Future<void> deleteTrack(String id) async {
    _requireTrackEditor();
    await _publishSealed(
        topics.track(id), TrackDoc.tombstone(id, rev: (_trackRevs[id] ?? 0) + 1, now: _now()).encode());
  }

  /// Owner only: updates name, description or settings.
  Future<void> updateProject({String? name, String? description, ProjectSettings? settings}) async {
    _requireOwner();
    await _publishProject(project.next(name: name, description: description, settings: settings, now: _now()));
  }

  /// Owner only: allows [memberId] to publish and delete tracks.
  Future<void> addEditor(String memberId) async {
    _requireOwner();
    publicKeyFromId(memberId);
    await _publishProject(project.next(editors: {...project.editors, memberId}, now: _now()));
  }

  /// Owner only: revokes track editing rights of [memberId].
  Future<void> removeEditor(String memberId) async {
    _requireOwner();
    await _publishProject(project.next(editors: {...project.editors}..remove(memberId), now: _now()));
  }

  /// Shares this device's position; the broker drops it after the project's
  /// position TTL unless it is refreshed.
  Future<void> publishPosition(Position position) async {
    _requireUnlocked();
    await _publishSealed(topics.position(_me.id), position.encode(), expiry: project.settings.positionTtl);
    _sharingPosition = true;
  }

  /// Stops sharing this device's position.
  Future<void> clearPosition() async {
    await _publishRaw(topics.position(_me.id), Uint8List(0));
    _sharingPosition = false;
  }

  /// Publishes this member's display name.
  Future<void> setMemberName(String name) async {
    _requireUnlocked();
    await _publishSealed(topics.member(_me.id), MemberDoc(name: name, updated: _now()).encode());
  }

  /// Owner only: changes the project password.
  ///
  /// Publishes the new metadata first, which locks every other session until
  /// [unlock] is called with the new password; then re-encrypts the project
  /// document, all tracks (re-signed by the owner) and tombstones, and the
  /// owner's own profile under the new key, and clears other members'
  /// profiles and positions (they re-publish after unlocking).
  Future<void> changePassword(String newPassword, {KdfParams? kdf}) async {
    _requireOwner();
    final params = kdf ?? KdfParams.generate(_c);
    final newKey = ProjectKey.derive(_c, newPassword, params);
    final oldKey = _key!;
    final tracks = [..._tracks.values];
    final tombstones = [
      for (final id in _trackRevs.keys)
        if (!_tracks.containsKey(id)) id
    ];
    final myMember = _members[_me.id];
    final others = [
      for (final t in _raw.keys)
        if (topics.parse(t) case TopicRef(kind: TopicKind.member || TopicKind.position, :final id)
            when id != _me.id)
          t
    ];

    final meta = ProjectMeta(kdf: params, keyCheck: newKey.check, rev: _meta!.rev + 1);
    _key = newKey;
    oldKey.dispose();
    await _publishMeta(meta);
    await _publishProject(project.next(now: _now()));
    for (final t in tracks) {
      await _publishSealed(
          topics.track(t.id),
          TrackDoc(id: t.id, rev: t.rev + 1, updated: _now(), gpx: t.gpx).encode());
    }
    for (final id in tombstones) {
      await _publishSealed(topics.track(id), TrackDoc.tombstone(id, rev: _trackRevs[id]! + 1, now: _now()).encode());
    }
    if (myMember != null) await setMemberName(myMember.name);
    await clearPosition();
    for (final t in others) {
      await _publishRaw(t, Uint8List(0));
    }
  }

  /// Derives the key from [password] and (re)loads all content. Used after
  /// [PasswordChanged]; throws [WrongPasswordException].
  Future<void> unlock(String password) async {
    final meta = _meta ?? (throw StateError('project metadata not received yet'));
    final key = ProjectKey.derive(_c, password, meta.kdf);
    if (!bytesEqual(key.check, meta.keyCheck)) {
      key.dispose();
      throw const WrongPasswordException();
    }
    _key?.dispose();
    _key = key;
    _reprocessAll();
  }

  /// Waits until every message the broker had queued for this session before
  /// the call has been received — in particular all retained messages after
  /// (re)subscribing.
  ///
  /// Implemented as a barrier: an empty, non-retained probe is published to a
  /// random `sync/<nonce>` topic of the project; the broker delivers it behind
  /// the messages already queued for this subscription.
  Future<void> sync({Duration timeout = const Duration(seconds: 10)}) async {
    final topic = topics.sync(b64u(_c.randomBytes(9)));
    final done = _syncWaiters[topic] = Completer<void>();
    try {
      await _transport.publish(topic, Uint8List(0));
      await done.future.timeout(timeout, onTimeout: () => throw TransportException('sync timed out'));
    } finally {
      _syncWaiters.remove(topic);
    }
  }

  /// Owner only: removes every retained message of the project from the
  /// broker, then closes the session.
  Future<void> deleteProject() async {
    _requireOwner();
    final all = _raw.keys.toList()
      ..sort((a, b) => _order(topics.parse(b)!).compareTo(_order(topics.parse(a)!)));
    for (final t in all) {
      await _transport.publish(t, Uint8List(0), retain: true);
    }
    await close(clearPosition: false);
  }

  /// Stops syncing. By default also clears the position shared by this
  /// session (a position shared by another session of the same identity, e.g.
  /// a background service, is left alone).
  Future<void> close({bool clearPosition = true}) async {
    if (_closed) return;
    if (clearPosition && _sharingPosition && _transport.state == TransportState.connected) {
      await _transport.publish(topics.position(_me.id), Uint8List(0), retain: true);
    }
    _closed = true;
    _pruneTimer?.cancel();
    await _sub?.cancel();
    if (_transport.state == TransportState.connected) {
      await _transport.unsubscribe(topics.all);
    }
    _key?.dispose();
    _key = null;
    await _events.close();
  }

  // ------------------------------------------------------------ internals

  static Future<void> _ensureConnected(Transport t) async {
    if (t.state != TransportState.connected) await t.connect();
  }

  DateTime _now() => _clock().toUtc();

  Future<void> _start() async {
    _sub = _transport.messages.listen((m) => _onMessage(m.topic, m.payload));
    await _transport.subscribe(topics.all);
    _pruneTimer = Timer.periodic(_pruneInterval, (_) => _prunePositions());
  }

  void _emit(SessionEvent e) {
    if (!_closed) _events.add(e);
  }

  void _requireUnlocked() {
    if (_closed) throw StateError('session closed');
    if (locked) throw StateError('session locked: the project password changed');
  }

  void _requireOwner() {
    _requireUnlocked();
    if (!isOwner) throw const AuthorizationException('only the project owner can do this');
  }

  void _requireTrackEditor() {
    _requireUnlocked();
    if (!project.canEditTracks(_me.id)) {
      throw const AuthorizationException('not allowed to edit tracks of this project');
    }
  }

  Future<void> _publishMeta(ProjectMeta meta) async {
    final data = meta.seal(topic: topics.meta, owner: _me);
    await _transport.publish(topics.meta, data, retain: true);
    _onMessage(topics.meta, data);
  }

  Future<void> _publishProject(ProjectDoc doc) => _publishSealed(topics.project, doc.encode());

  Future<void> _publishSealed(String topic, Uint8List body, {Duration? expiry}) async {
    final data = _env.seal(key: _key!.dataKey, topic: topic, body: body, signer: _me);
    await _transport.publish(topic, data, retain: true, expiry: expiry);
    _onMessage(topic, data);
  }

  Future<void> _publishRaw(String topic, Uint8List data) async {
    await _transport.publish(topic, data, retain: true);
    _onMessage(topic, data);
  }

  void _onMessage(String topic, Uint8List payload) {
    if (_closed) return;
    final waiter = _syncWaiters[topic];
    if (waiter != null) return waiter.complete();
    final ref = topics.parse(topic);
    if (ref == null) return;
    final prev = _raw[topic];
    if (payload.isEmpty ? prev == null : (prev != null && bytesEqual(prev, payload))) return;
    if (payload.isEmpty) {
      _raw.remove(topic);
    } else {
      _raw[topic] = payload;
    }
    _process(ref, topic, payload);
  }

  /// Processing order after unlock: meta, project, then everything else.
  static int _order(TopicRef r) => switch (r.kind) { TopicKind.meta => 0, TopicKind.project => 1, _ => 2 };

  void _reprocessAll() {
    final entries = [
      for (final e in _raw.entries) (topics.parse(e.key)!, e.key, e.value)
    ]..sort((a, b) => _order(a.$1).compareTo(_order(b.$1)));
    for (final (ref, topic, payload) in entries) {
      if (ref.kind != TopicKind.meta) _process(ref, topic, payload);
    }
  }

  void _process(TopicRef ref, String topic, Uint8List payload) {
    try {
      if (ref.kind == TopicKind.meta) return _onMeta(topic, payload);
      if (locked) return; // kept in _raw until unlock
      switch (ref.kind) {
        case TopicKind.meta:
          break;
        case TopicKind.project:
          _onProject(topic, payload);
        case TopicKind.track:
          _onTrack(ref.id!, topic, payload);
        case TopicKind.member:
          _onMember(ref.id!, topic, payload);
        case TopicKind.position:
          _onPosition(ref.id!, topic, payload);
      }
    } on PepException catch (e) {
      _emit(MessageRejected(topic, e));
    }
  }

  Opened _open(String topic, Uint8List payload) => _env.open(key: _key!.dataKey, topic: topic, data: payload);

  void _onMeta(String topic, Uint8List payload) {
    if (payload.isEmpty) {
      if (_meta != null) _emit(const ProjectDeleted());
      return;
    }
    final meta = ProjectMeta.open(_c, topic: topic, data: payload, ownerKey: _ownerKey);
    final current = _meta;
    if (current != null && meta.rev <= current.rev) return;
    _meta = meta;
    if (!_metaArrived.isCompleted) _metaArrived.complete();
    if (current != null && _key != null && !bytesEqual(_key!.check, meta.keyCheck)) {
      _key!.dispose();
      _key = null;
      _emit(const PasswordChanged());
    }
  }

  void _onProject(String topic, Uint8List payload) {
    if (payload.isEmpty) {
      if (_project != null) _emit(const ProjectDeleted());
      return;
    }
    final o = _open(topic, payload);
    if (o.signerId != ownerId) throw const AuthorizationException('project document not signed by the owner');
    final doc = ProjectDoc.decode(o.body);
    if (doc.id != projectId || doc.ownerId != ownerId) {
      throw const FormatPepException('project document id/owner mismatch');
    }
    final current = _project;
    if (current != null && doc.rev <= current.rev) return;
    _project = doc;
    if (!_projectArrived.isCompleted) _projectArrived.complete();
    _emit(ProjectUpdated(doc));
    for (final t in [..._pendingAuth]) {
      final raw = _raw[t];
      if (raw != null) _process(topics.parse(t)!, t, raw);
    }
  }

  void _onTrack(String id, String topic, Uint8List payload) {
    if (payload.isEmpty) {
      _pendingAuth.remove(topic);
      if (_tracks.remove(id) != null) _emit(TrackRemoved(id));
      return;
    }
    final o = _open(topic, payload);
    final p = _project;
    if (p == null || !p.canEditTracks(o.signerId)) {
      _pendingAuth.add(topic);
      throw AuthorizationException('track signed by ${o.signerId}, who may not edit tracks');
    }
    _pendingAuth.remove(topic);
    final doc = TrackDoc.decode(o.body);
    if (doc.id != id) throw const FormatPepException('track id does not match its topic');
    final known = _trackRevs[id];
    if (known != null && doc.rev <= known) return;
    _trackRevs[id] = doc.rev;
    if (doc.deleted) {
      _trackSigners.remove(id);
      if (_tracks.remove(id) != null) _emit(TrackRemoved(id));
    } else {
      _tracks[id] = doc;
      _trackSigners[id] = o.signerId;
      _emit(TrackUpdated(doc, signerId: o.signerId));
    }
  }

  void _onMember(String id, String topic, Uint8List payload) {
    if (payload.isEmpty) {
      if (_members.remove(id) != null) _emit(MemberRemoved(id));
      return;
    }
    final o = _open(topic, payload);
    if (o.signerId != id) throw const AuthorizationException('member profile not signed by that member');
    final m = MemberDoc.decode(o.body);
    final current = _members[id];
    if (current != null && m.updated.isBefore(current.updated)) return;
    _members[id] = m;
    _emit(MemberUpdated(id, m));
  }

  void _onPosition(String id, String topic, Uint8List payload) {
    if (payload.isEmpty) {
      if (_positions.remove(id) != null) _emit(PositionRemoved(id));
      return;
    }
    final o = _open(topic, payload);
    if (o.signerId != id) throw const AuthorizationException('position not signed by that member');
    final pos = Position.decode(o.body);
    final current = _positions[id];
    if (current != null && pos.time.isBefore(current.time)) return;
    if (!pos.isFresh(project.settings.positionTtl, now: _now())) {
      if (_positions.remove(id) != null) _emit(PositionRemoved(id));
      return;
    }
    _positions[id] = pos;
    _emit(PositionUpdated(id, pos));
  }

  void _prunePositions() {
    if (_project == null) return;
    final ttl = project.settings.positionTtl;
    final now = _now();
    final stale = [
      for (final e in _positions.entries)
        if (!e.value.isFresh(ttl, now: now)) e.key
    ];
    for (final id in stale) {
      _positions.remove(id);
      _emit(PositionRemoved(id));
    }
  }

  /// Runs the position expiry check now (normally periodic). For tests and
  /// apps resuming from background.
  void prunePositions() => _prunePositions();
}
