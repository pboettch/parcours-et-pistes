import 'dart:typed_data';

import '../codec/bytes.dart';
import '../codec/json.dart';
import '../crypto/pep_crypto.dart';
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

/// One link of the ownership chain: [memberId] became owner, attested by the
/// previous owner's [signature] over [toSign] (null for the creator).
class OwnerLink {
  const OwnerLink(this.memberId, [this.signature]);

  factory OwnerLink.fromJson(Json j) {
    final sig = j.opt<String>('sig');
    return OwnerLink(j.req<String>('id'), sig == null ? null : unb64u(sig));
  }

  final String memberId;
  final Uint8List? signature;

  /// What the previous owner signs to hand the channel over to [newOwnerId] as
  /// chain entry number [index].
  static Uint8List toSign(String channelId, int index, String newOwnerId) =>
      (ByteWriter()
            ..bytes(utf8Bytes('pep-owner-v1'))
            ..lp16(utf8Bytes(channelId))
            ..u32(index)
            ..bytes(publicKeyFromId(newOwnerId)))
          .take();

  Json toJson() => {'id': memberId, if (signature != null) 'sig': b64u(signature!)};

  @override
  bool operator ==(Object other) =>
      other is OwnerLink &&
      other.memberId == memberId &&
      (other.signature == null) == (signature == null) &&
      (signature == null || bytesEqual(signature!, other.signature!));

  @override
  int get hashCode => memberId.hashCode;
}

/// Owner-signed access list (`acl` topic): the ownership chain, the editors,
/// the collections of the channel with their policies, and an optional pending
/// ownership [offer].
///
/// Collections are declared here, by the owner, rather than hard-coded in the
/// apps: every client enforces the rules of every declared collection, even
/// ones it does not understand (items of those are passed through as opaque
/// bytes). Items in undeclared collections are rejected.
///
/// Ownership transfer: the owner publishes an [offer] (the next chain link,
/// signed by them); the designated member accepts by publishing an access list
/// whose chain ends with that link, signed with their own key. Join links pin
/// any key of the chain; clients verify the chain from that key onwards.
class ChannelAcl {
  ChannelAcl({required this.owners, this.editors = const {}, required this.collections, this.offer}) {
    if (owners.isEmpty) throw const FormatPepException('empty ownership chain');
    if (owners.length > maxOwners) throw const FormatPepException('ownership chain too long');
    for (final o in owners) {
      publicKeyFromId(o.memberId);
    }
    if (offer != null) publicKeyFromId(offer!.memberId);
    editors.forEach(publicKeyFromId);
    collections.keys.forEach(checkCollection);
    if (collections.length > maxCollections) throw const FormatPepException('too many collections');
  }

  factory ChannelAcl.initial({
    required String ownerId,
    Set<String> editors = const {},
    required Map<String, CollectionPolicy> collections,
  }) => ChannelAcl(owners: [OwnerLink(ownerId)], editors: editors, collections: collections);

  factory ChannelAcl.fromJson(Json j) {
    j.checkVersion(version);
    final offer = j.opt<Json>('offer');
    return ChannelAcl(
      owners: List.unmodifiable([
        for (final o in j.req<List<dynamic>>('owners'))
          OwnerLink.fromJson(o is Json ? o : throw const FormatPepException('invalid ownership chain')),
      ]),
      editors: Set.unmodifiable(j.strList('editors')),
      collections: Map.unmodifiable({
        for (final e in j.req<Json>('collections').entries)
          e.key: CollectionPolicy.fromJson(e.value is Json ? e.value as Json : const {}),
      }),
      offer: offer == null ? null : OwnerLink.fromJson(offer),
    );
  }

  factory ChannelAcl.decode(Uint8List b) => ChannelAcl.fromJson(decodeJson(b));

  static const version = 1;
  static const maxCollections = 64;
  static const maxOwners = 256;

  /// Ownership chain, creator first; the last entry is the current owner.
  final List<OwnerLink> owners;
  final Set<String> editors;
  final Map<String, CollectionPolicy> collections;

  /// Pending ownership offer: the next chain link, signed by the current owner.
  final OwnerLink? offer;

  String get ownerId => owners.last.memberId;

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
      Writers.editors => memberId == ownerId || editors.contains(memberId),
      Writers.self => isSelfItem(memberId, itemId),
    };
  }

  /// Verifies the chain from the entry of [anchorId] (e.g. the owner pinned in
  /// a join link) to the current owner. Throws [AuthorizationException].
  void verifyChain(PepCrypto c, String channelId, String anchorId) {
    final start = owners.lastIndexWhere((o) => o.memberId == anchorId);
    if (start < 0) throw const AuthorizationException('the trusted owner is not in the ownership chain');
    for (var i = start + 1; i < owners.length; i++) {
      final sig = owners[i].signature;
      if (sig == null ||
          !Identity.verify(
            c,
            OwnerLink.toSign(channelId, i, owners[i].memberId),
            sig,
            publicKeyFromId(owners[i - 1].memberId),
          )) {
        throw const AuthorizationException('invalid ownership chain');
      }
    }
  }

  /// Whether the offer (if any) is validly signed by the current owner.
  bool offerValid(PepCrypto c, String channelId) {
    final o = offer;
    return o?.signature != null &&
        Identity.verify(
          c,
          OwnerLink.toSign(channelId, owners.length, o!.memberId),
          o.signature!,
          publicKeyFromId(ownerId),
        );
  }

  /// Whether [other]'s chain starts with this chain (ownership only moves forward).
  bool isChainPrefixOf(ChannelAcl other) =>
      owners.length <= other.owners.length &&
      [for (var i = 0; i < owners.length; i++) owners[i] == other.owners[i]].every((x) => x);

  ChannelAcl copyWith({
    List<OwnerLink>? owners,
    Set<String>? editors,
    Map<String, CollectionPolicy>? collections,
    OwnerLink? offer,
    bool clearOffer = false,
  }) => ChannelAcl(
    owners: List.unmodifiable(owners ?? this.owners),
    editors: Set.unmodifiable(editors ?? this.editors),
    collections: Map.unmodifiable(collections ?? this.collections),
    offer: clearOffer ? null : (offer ?? this.offer),
  );

  Json toJson() => {
    'v': version,
    'owners': [for (final o in owners) o.toJson()],
    'editors': editors.toList()..sort(),
    'collections': {for (final e in collections.entries) e.key: e.value.toJson()},
    if (offer != null) 'offer': offer!.toJson(),
  };

  Uint8List encode() => encodeJson(toJson());
}
