import 'dart:typed_data';

import '../codec/json.dart';
import '../crypto/identity.dart';
import '../errors.dart';
import '../protocol/topics.dart';

/// Who may publish items of a collection.
enum Writers {
  /// Only the channel owner.
  owner,

  /// The owner and the members listed as editors.
  editors,

  /// Every member, but only the item whose id is their own member id.
  self,
}

/// Access and retention rules of one collection.
class CollectionPolicy {
  const CollectionPolicy(this.writers, {this.ttl});

  factory CollectionPolicy.fromJson(Json j) {
    final w = j.req<String>('w');
    final writers = Writers.values.firstWhere((x) => x.name == w,
        orElse: () => throw FormatPepException('unknown writer policy "$w"'));
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

/// Owner-signed access list (`acl` topic): the owner, the editors and the
/// collections of the channel with their policies.
///
/// Collections are declared here, by the owner, rather than hard-coded in the
/// apps: every client enforces the rules of every declared collection, even
/// ones it does not understand (items of those are passed through as opaque
/// bytes). Items in undeclared collections are rejected.
class ChannelAcl {
  ChannelAcl({required this.ownerId, this.editors = const {}, required this.collections}) {
    publicKeyFromId(ownerId);
    editors.forEach(publicKeyFromId);
    collections.keys.forEach(checkCollection);
    if (collections.length > maxCollections) throw const FormatPepException('too many collections');
  }

  factory ChannelAcl.fromJson(Json j) {
    j.checkVersion(version);
    return ChannelAcl(
      ownerId: j.req<String>('owner'),
      editors: Set.unmodifiable(j.strList('editors')),
      collections: Map.unmodifiable({
        for (final e in j.req<Json>('collections').entries)
          e.key: CollectionPolicy.fromJson(e.value is Json ? e.value as Json : const {}),
      }),
    );
  }

  factory ChannelAcl.decode(Uint8List b) => ChannelAcl.fromJson(decodeJson(b));

  static const version = 1;
  static const maxCollections = 64;

  final String ownerId;
  final Set<String> editors;
  final Map<String, CollectionPolicy> collections;

  /// Whether [memberId] may publish (or delete) item [itemId] of [collection].
  bool canWrite(String memberId, String collection, String itemId) {
    final p = collections[collection];
    if (p == null) return false;
    return switch (p.writers) {
      Writers.owner => memberId == ownerId,
      Writers.editors => memberId == ownerId || editors.contains(memberId),
      Writers.self => memberId == itemId,
    };
  }

  ChannelAcl copyWith({Set<String>? editors, Map<String, CollectionPolicy>? collections}) => ChannelAcl(
        ownerId: ownerId,
        editors: Set.unmodifiable(editors ?? this.editors),
        collections: Map.unmodifiable(collections ?? this.collections),
      );

  Json toJson() => {
        'v': version,
        'owner': ownerId,
        'editors': editors.toList()..sort(),
        'collections': {for (final e in collections.entries) e.key: e.value.toJson()},
      };

  Uint8List encode() => encodeJson(toJson());
}
