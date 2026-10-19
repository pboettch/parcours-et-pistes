import 'dart:typed_data';

import '../codec/json.dart';
import '../crypto/identity.dart';
import '../errors.dart';
import '../protocol/ids.dart';
import '../protocol/topics.dart';

/// Who may publish items of a collection.
enum Writers {
  /// Only the channel owner.
  owner,

  /// One writer per item: the member the owner assigned it to in the access
  /// list ([ChannelAcl.assignees]). The owner may always write too, but only
  /// re-signs (reassignment) or writes unassigned items.
  assigned,

  /// Every member, but only the items whose id is their own pseudonym
  /// (optionally with a `.tag` suffix, see `SecureChannel.selfItemId`).
  self,
}

/// Access and retention rules of one collection.
class CollectionPolicy {
  const CollectionPolicy(this.writers, {this.ttl});

  factory CollectionPolicy.fromJson(Json j) {
    final w = j.req<String>('w');
    final writers = Writers.values.firstWhere(
      (x) => x.name == w,
      orElse: () => throw FormatPepException('unknown writer policy "$w"'),
    );
    final ttl = j.opt<int>('ttl');
    if (ttl != null && (ttl < minTtl.inSeconds || ttl > maxTtl.inSeconds)) {
      throw FormatPepException('ttl $ttl out of range');
    }
    return CollectionPolicy(writers, ttl: ttl == null ? null : Duration(seconds: ttl));
  }

  static const minTtl = Duration(seconds: 10);
  static const maxTtl = Duration(days: 7);

  final Writers writers;

  /// Ephemeral collection: items expire this long after being published (the
  /// broker drops them via MQTT message expiry; clients filter by publish
  /// time). Null = persistent.
  final Duration? ttl;

  bool get ephemeral => ttl != null;

  CollectionPolicy withTtl(Duration? ttl) => CollectionPolicy(writers, ttl: ttl);

  Json toJson() => {'w': writers.name, if (ttl != null) 'ttl': ttl!.inSeconds};

  @override
  bool operator ==(Object other) => other is CollectionPolicy && other.writers == writers && other.ttl == ttl;

  @override
  int get hashCode => Object.hash(writers, ttl);
}

/// Owner-signed access list (`acl` topic): the owner, the collections of the
/// channel with their policies, and the writers of the items of `assigned`
/// collections.
///
/// Collections are declared here, by the owner, rather than hard-coded in the
/// apps: every client enforces the rules of every declared collection, even
/// ones it does not understand (items of those are passed through as opaque
/// bytes). Items in undeclared collections are rejected.
///
/// The owner is the channel's creator and never changes (the join link pins
/// it): handing a project over means creating a new one.
class ChannelAcl {
  ChannelAcl({required this.ownerId, required this.collections, this.assignees = const {}}) {
    publicKeyFromId(ownerId);
    collections.keys.forEach(checkCollection);
    if (collections.length > maxCollections) throw const FormatPepException('too many collections');
    var n = 0;
    for (final MapEntry(key: c, value: items) in assignees.entries) {
      if (collections[c]?.writers != Writers.assigned) {
        throw FormatPepException('assignments for "$c", which is not an assigned collection');
      }
      for (final MapEntry(key: id, value: m) in items.entries) {
        checkTopicId(id);
        publicKeyFromId(m);
      }
      n += items.length;
    }
    if (n > maxAssignments) throw const FormatPepException('too many assignments');
  }

  factory ChannelAcl.fromJson(Json j) {
    j.checkVersion(version);
    return ChannelAcl(
      ownerId: j.req<String>('owner'),
      collections: Map.unmodifiable({
        for (final e in j.req<Json>('collections').entries)
          e.key: CollectionPolicy.fromJson(e.value is Json ? e.value as Json : const {}),
      }),
      assignees: Map.unmodifiable({
        for (final e in j.optMap('assign').entries)
          e.key: Map<String, String>.unmodifiable(
            e.value is Json
                ? (e.value as Json).map(
                    (id, m) => MapEntry(id, m is String ? m : throw const FormatPepException('invalid assignment')),
                  )
                : throw const FormatPepException('invalid assignments'),
          ),
      }),
    );
  }

  factory ChannelAcl.decode(Uint8List b) => ChannelAcl.fromJson(decodeJson(b));

  static const version = 1;
  static const maxCollections = 64;
  static const maxAssignments = 4096;

  /// The channel's owner (its creator).
  final String ownerId;

  final Map<String, CollectionPolicy> collections;

  /// Writers of the items of `assigned` collections: collection → item id →
  /// member id. Items without an entry are written by the owner.
  final Map<String, Map<String, String>> assignees;

  /// The member assigned to item [itemId] of [collection], if any.
  String? assigneeOf(String collection, String itemId) => assignees[collection]?[itemId];

  /// Whether [memberId] may publish (or delete) item [itemId] of [collection].
  /// [isSelfItem] decides whether an item id belongs to a member (`self`
  /// collections use per-channel pseudonyms, computed by the channel).
  bool canWrite(
    String memberId,
    String collection,
    String itemId, {
    required bool Function(String memberId, String itemId) isSelfItem,
  }) {
    final p = collections[collection];
    if (p == null) return false;
    return switch (p.writers) {
      Writers.owner => memberId == ownerId,
      Writers.assigned => memberId == ownerId || assigneeOf(collection, itemId) == memberId,
      Writers.self => isSelfItem(memberId, itemId),
    };
  }

  ChannelAcl copyWith({Map<String, CollectionPolicy>? collections, Map<String, Map<String, String>>? assignees}) {
    final c = collections ?? this.collections;
    return ChannelAcl(
      ownerId: ownerId,
      collections: Map.unmodifiable(c),
      // Assignments of collections no longer `assigned` are dropped.
      assignees: Map.unmodifiable({
        for (final e in (assignees ?? this.assignees).entries)
          if (e.value.isNotEmpty && c[e.key]?.writers == Writers.assigned)
            e.key: Map<String, String>.unmodifiable(e.value),
      }),
    );
  }

  /// This access list with item [itemId] of [collection] assigned to
  /// [memberId] (null: back to the owner).
  ChannelAcl withAssignee(String collection, String itemId, String? memberId) {
    final items = {...?assignees[collection]};
    if (memberId == null) {
      items.remove(itemId);
    } else {
      items[itemId] = memberId;
    }
    return copyWith(assignees: {...assignees, collection: items});
  }

  Json toJson() => {
    'v': version,
    'owner': ownerId,
    'collections': {for (final e in collections.entries) e.key: e.value.toJson()},
    if (assignees.isNotEmpty)
      'assign': {
        for (final c in assignees.keys.toList()..sort())
          c: {for (final id in assignees[c]!.keys.toList()..sort()) id: assignees[c]![id]},
      },
  };

  Uint8List encode() => encodeJson(toJson());
}
