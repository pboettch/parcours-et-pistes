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

  @override
  String toString() => 'ChannelItem($collection/$id rev $rev by $signerId, ${body.length} bytes)';
}
