import 'dart:typed_data';

/// A verified item of a channel collection.
class ChannelItem {
  ChannelItem({
    required this.collection,
    required this.id,
    required this.rev,
    required this.time,
    required this.signerId,
    required this.body,
    this.recipients,
  });

  final String collection;
  final String id;

  /// Revision; each update increments it.
  final int rev;

  /// Publish time (signed by the publisher).
  final DateTime time;

  /// Member who published this revision.
  final String signerId;

  /// Opaque content, decoded by the content layer.
  final Uint8List body;

  /// Members allowed to read this item (always including the owner at publish
  /// time and the publisher); null = every member.
  final Set<String>? recipients;

  bool get restricted => recipients != null;

  @override
  String toString() => 'ChannelItem($collection/$id rev $rev by $signerId, ${body.length} bytes)';
}
