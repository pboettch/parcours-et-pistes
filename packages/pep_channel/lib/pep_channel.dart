/// Secure channel of Parcours et Pistes: end-to-end encrypted, signed and
/// access-controlled collections of opaque items, synchronized over MQTT 5.
///
/// Knows nothing about the content it carries (see `pep_content`).
library;

export 'src/channel/acl.dart';
export 'src/channel/events.dart';
export 'src/channel/item.dart';
export 'src/channel/meta.dart';
export 'src/channel/secure_channel.dart';
export 'src/codec/bytes.dart' show b64u, unb64u, utf8Bytes;
export 'src/crypto/envelope.dart';
export 'src/crypto/identity.dart';
export 'src/crypto/kdf.dart';
export 'src/crypto/pep_crypto.dart';
export 'src/errors.dart';
export 'src/protocol/ids.dart' show newUuid, newItemId, isChannelId, isTopicId;
export 'src/protocol/join_link.dart';
export 'src/protocol/topics.dart';
export 'src/transport/memory_transport.dart';
export 'src/transport/mqtt5_transport.dart';
export 'src/transport/transport.dart';
