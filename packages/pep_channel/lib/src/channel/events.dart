import '../errors.dart';
import 'acl.dart';
import 'item.dart';

/// Changes observed by a `SecureChannel`.
sealed class ChannelEvent {
  const ChannelEvent();
}

class AclUpdated extends ChannelEvent {
  const AclUpdated(this.acl);

  final ChannelAcl acl;
}

class ItemUpdated extends ChannelEvent {
  const ItemUpdated(this.item);

  final ChannelItem item;
}

/// An item was deleted (tombstone), cleared, or expired.
class ItemRemoved extends ChannelEvent {
  const ItemRemoved(this.collection, this.id, {this.expired = false});

  final String collection;
  final String id;

  /// Removed because its collection's TTL elapsed.
  final bool expired;
}

/// The owner changed the password; the channel is locked until
/// `SecureChannel.unlock` succeeds with the new one.
class PasswordChanged extends ChannelEvent {
  const PasswordChanged();
}

/// The owner deleted the channel (metadata or access list cleared).
class ChannelDeleted extends ChannelEvent {
  const ChannelDeleted();
}

/// A message could not be decrypted, verified or authorized and was ignored.
class MessageRejected extends ChannelEvent {
  const MessageRejected(this.topic, this.error);

  final String topic;
  final PepException error;

  @override
  String toString() => 'MessageRejected($topic, $error)';
}
