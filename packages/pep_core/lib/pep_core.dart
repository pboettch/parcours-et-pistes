/// Shared low-level library of Parcours et Pistes: end-to-end encrypted sharing
/// of search-dog trails (GPX) and live positions over MQTT.
library;

export 'src/codec/bytes.dart' show b64u, unb64u, utf8Bytes;
export 'src/crypto/envelope.dart';
export 'src/crypto/identity.dart';
export 'src/crypto/kdf.dart';
export 'src/crypto/pep_crypto.dart';
export 'src/errors.dart';
export 'src/model/gpx.dart';
export 'src/model/member.dart';
export 'src/model/meta.dart';
export 'src/model/position.dart';
export 'src/model/project_doc.dart';
export 'src/model/track_doc.dart';
export 'src/protocol/ids.dart' show newUuid, newTrackId, isProjectId, isTopicId;
export 'src/protocol/join_link.dart';
export 'src/protocol/topics.dart';
export 'src/transport/memory_transport.dart';
export 'src/transport/mqtt5_transport.dart';
export 'src/transport/transport.dart';
export 'src/session/project_session.dart';
export 'src/session/session_events.dart';
