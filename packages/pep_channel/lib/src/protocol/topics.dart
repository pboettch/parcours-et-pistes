import '../errors.dart';
import 'ids.dart';

enum TopicKind { meta, acl, item, sync }

/// A parsed channel topic.
class TopicRef {
  const TopicRef(this.kind, {this.collection, this.id});

  final TopicKind kind;

  /// Collection name (items only).
  final String? collection;

  /// Item id (items) or nonce (sync).
  final String? id;

  @override
  bool operator ==(Object other) =>
      other is TopicRef && other.kind == kind && other.collection == collection && other.id == id;

  @override
  int get hashCode => Object.hash(kind, collection, id);

  @override
  String toString() => 'TopicRef($kind, $collection, $id)';
}

final _collectionRe = RegExp(r'^[a-z][a-z0-9_]{0,31}$');

/// Names that cannot be used as collections.
const reservedTopicNames = {'meta', 'acl', 'sync'};

bool isCollectionName(String s) => _collectionRe.hasMatch(s) && !reservedTopicNames.contains(s);

String checkCollection(String s) => isCollectionName(s) ? s : throw FormatPepException('invalid collection name "$s"');

/// Topic layout of one channel:
///
/// ```text
/// <base>/<uuid>/meta               owner-signed plaintext: KDF params, key check
/// <base>/<uuid>/acl                owner-signed access list (editors, collections)
/// <base>/<uuid>/<collection>/<id>  sealed items
/// <base>/<uuid>/sync/<nonce>       empty non-retained barrier probes
/// ```
class ChannelTopics {
  ChannelTopics(String channelId, {this.base = defaultBase}) : channelId = checkChannelId(channelId) {
    if (base.isEmpty || base.contains(RegExp(r'[#+]')) || base.startsWith('/') || base.endsWith('/')) {
      throw FormatPepException('invalid topic base "$base"');
    }
  }

  static const defaultBase = 'pep/v1';

  final String base;
  final String channelId;

  String get _root => '$base/$channelId';

  /// Subscription filter for everything in the channel (literal UUID, no
  /// wildcard above it).
  String get all => '$_root/#';
  String get meta => '$_root/meta';
  String get acl => '$_root/acl';
  String item(String collection, String id) => '$_root/${checkCollection(collection)}/${checkTopicId(id)}';
  String sync(String nonce) => '$_root/sync/${checkTopicId(nonce)}';

  /// Returns null for topics outside this channel or with an unknown layout.
  TopicRef? parse(String topic) {
    if (!topic.startsWith('$_root/')) return null;
    final parts = topic.substring(_root.length + 1).split('/');
    return switch (parts) {
      ['meta'] => const TopicRef(TopicKind.meta),
      ['acl'] => const TopicRef(TopicKind.acl),
      ['sync', final n] when isTopicId(n) => TopicRef(TopicKind.sync, id: n),
      [final c, final id] when isCollectionName(c) && isTopicId(id) => TopicRef(TopicKind.item, collection: c, id: id),
      _ => null,
    };
  }
}
