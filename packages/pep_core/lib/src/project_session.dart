import 'dart:async';
import 'dart:typed_data';

import 'package:pep_channel/pep_channel.dart' as ch;
import 'package:pep_channel/pep_channel.dart' hide PasswordChanged, MessageRejected;
import 'package:pep_content/pep_content.dart' hide utf8Bytes;

import 'collections.dart';
import 'project.dart';
import 'session_events.dart';
import 'track.dart';

/// A Parcours et Pistes project on one device: the content model
/// (`pep_content`) mapped onto a [SecureChannel] (`pep_channel`), see
/// [PepCollections].
///
/// All security (encryption, signatures, access rules, revisions, expiry,
/// password changes) is the channel's job; this class only encodes and decodes
/// content. Items of collections it does not know (content types added by
/// newer app versions) are ignored.
class ProjectSession {
  ProjectSession._(this.channel) {
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
    await channel.put(PepCollections.info, PepCollections.infoId,
        ProjectInfo(name: name, description: description, discipline: discipline).encode());
    return ProjectSession._(channel);
  }

  /// Joins an existing project from its invitation [link] and [password].
  /// Returns with the complete project state (all tracks included).
  ///
  /// Throws [WrongPasswordException], or [ChannelNotFoundException] when no
  /// project signed by the owner named in the link is found.
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
    final s = ProjectSession._(channel);
    if (s._projectOrNull == null) {
      await s.close(clearPosition: false);
      throw const ChannelNotFoundException('no valid project information in the channel');
    }
    return s;
  }

  /// The underlying secure channel (for advanced use and tests).
  final SecureChannel channel;

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

  Map<String, MemberProfile> get members => _all(PepCollections.member, (i) => _decode(i, MemberProfile.decode));

  /// Fresh positions by member id.
  Map<String, Position> get positions => _all(PepCollections.position, (i) => _decode(i, Position.decode));

  // -------------------------------------------------------------- actions

  /// Publishes a new track, or a new revision of track [id]. Everything about
  /// the track (name, objects, custom sections) is in the [gpx] document.
  Future<Track> publishTrack({String? id, required String gpx}) async {
    final parsed = Gpx.parse(gpx); // reject invalid GPX before publishing
    final item = await channel.put(PepCollections.track, id ?? channel.generateItemId(), utf8Bytes(gpx));
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

  Future<void> publishPosition(Position position) async {
    await channel.put(PepCollections.position, memberId, position.encode());
  }

  Future<void> clearPosition() => channel.delete(PepCollections.position, memberId);

  Future<void> setMemberName(String name) async {
    await channel.put(PepCollections.member, memberId, MemberProfile(name: name).encode());
  }

  /// Owner only; see [SecureChannel.changePassword].
  Future<void> changePassword(String newPassword, {KdfParams? kdf}) => channel.changePassword(newPassword, kdf: kdf);

  Future<void> unlock(String password) => channel.unlock(password);

  Future<void> sync({Duration timeout = const Duration(seconds: 10)}) => channel.sync(timeout: timeout);

  void prunePositions() => channel.prune();

  /// Owner only: removes the project from the broker and closes the session.
  Future<void> deleteProject() async {
    await channel.deleteChannel();
    await _shutdown();
  }

  /// Stops syncing; by default clears the position shared by this session.
  Future<void> close({bool clearPosition = true}) async {
    await channel.close(clearEphemeral: clearPosition);
    await _shutdown();
  }

  // ------------------------------------------------------------ internals

  Future<void> _shutdown() async {
    await _sub.cancel();
    if (!_events.isClosed) await _events.close();
  }

  void _emit(SessionEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  Map<String, T> _all<T>(String collection, T? Function(ChannelItem) decode) => Map.unmodifiable({
        for (final i in channel.items(collection).values) i.id: ?decode(i),
      });

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
      case ch.ItemUpdated(:final item):
        _onItem(item);
      case ch.ItemRemoved(:final collection, :final id):
        switch (collection) {
          case PepCollections.track:
            _emit(TrackRemoved(id));
          case PepCollections.member:
            _emit(MemberRemoved(id));
          case PepCollections.position:
            _emit(PositionRemoved(id));
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
        if (m != null) event = MemberUpdated(item.id, m);
      case PepCollections.position:
        final p = _decode(item, Position.decode);
        if (p != null) event = PositionUpdated(item.id, p);
      default:
        return; // content type unknown to this version: ignored
    }
    _emit(event ?? MessageRejected(topic, ContentFormatException('invalid ${item.collection} content')));
  }
}
