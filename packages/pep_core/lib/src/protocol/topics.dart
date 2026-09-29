import '../errors.dart';
import 'ids.dart';

enum TopicKind { meta, project, track, member, position }

/// A parsed project topic.
class TopicRef {
  const TopicRef(this.kind, [this.id]);

  final TopicKind kind;

  /// Track or member id, for `track`, `member` and `position` topics.
  final String? id;

  @override
  bool operator ==(Object other) => other is TopicRef && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);

  @override
  String toString() => 'TopicRef($kind, $id)';
}

/// Topic layout of one project:
///
/// ```text
/// <base>/<uuid>/meta             plaintext: format version, KDF params, key check
/// <base>/<uuid>/project          owner-signed project document
/// <base>/<uuid>/track/<id>       owner- or editor-signed track (or tombstone)
/// <base>/<uuid>/member/<id>      member profile, signed by that member
/// <base>/<uuid>/pos/<id>         live position, signed by that member, expires
/// ```
class ProjectTopics {
  ProjectTopics(String projectId, {this.base = defaultBase})
      : projectId = checkProjectId(projectId) {
    if (base.isEmpty || base.contains(RegExp(r'[#+]')) || base.startsWith('/') || base.endsWith('/')) {
      throw FormatPepException('invalid topic base "$base"');
    }
  }

  static const defaultBase = 'pep/v1';

  final String base;
  final String projectId;

  String get _root => '$base/$projectId';

  /// Subscription filter for everything in the project (literal UUID, no
  /// wildcard above it).
  String get all => '$_root/#';
  String get meta => '$_root/meta';
  String get project => '$_root/project';
  String track(String id) => '$_root/track/${checkTopicId(id)}';
  String member(String id) => '$_root/member/${checkTopicId(id)}';
  String position(String id) => '$_root/pos/${checkTopicId(id)}';

  /// Returns null for topics outside this project or with an unknown layout.
  TopicRef? parse(String topic) {
    if (!topic.startsWith('$_root/')) return null;
    final parts = topic.substring(_root.length + 1).split('/');
    switch (parts) {
      case ['meta']:
        return const TopicRef(TopicKind.meta);
      case ['project']:
        return const TopicRef(TopicKind.project);
      case ['track', final id] when isTopicId(id):
        return TopicRef(TopicKind.track, id);
      case ['member', final id] when isTopicId(id):
        return TopicRef(TopicKind.member, id);
      case ['pos', final id] when isTopicId(id):
        return TopicRef(TopicKind.position, id);
    }
    return null;
  }
}
