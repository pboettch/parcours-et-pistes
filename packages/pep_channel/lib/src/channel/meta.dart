import 'dart:typed_data';

import '../codec/bytes.dart';
import '../crypto/identity.dart';
import '../crypto/kdf.dart';
import '../crypto/pep_crypto.dart';
import '../errors.dart';
import '../codec/json.dart';

/// Plaintext `meta` document: everything needed to derive the project key.
/// Contains no names or other content.
///
/// It is signed by the channel owner (verified against the owner key from the
/// join link), so nobody else can make clients believe the password changed.
/// Wire format: `signature[64] | json`, signature over
/// `"pep-meta-v1" | lp16(topic) | json`.
class ChannelMeta {
  ChannelMeta({required this.kdf, required this.keyCheck, required this.rev});

  factory ChannelMeta.fromJson(Json j) {
    j.checkVersion(version);
    return ChannelMeta(
      kdf: KdfParams.fromJson(j.req<Json>('kdf')),
      keyCheck: unb64u(j.req<String>('check')),
      rev: j.req<int>('rev'),
    );
  }

  /// Verifies the owner signature and parses.
  factory ChannelMeta.open(PepCrypto c, {required String topic, required Uint8List data, required Uint8List ownerKey}) {
    if (!verifies(c, topic: topic, data: data, ownerKey: ownerKey)) {
      throw const AuthorizationException('meta not signed by the channel owner');
    }
    return ChannelMeta.parseUnverified(data);
  }

  /// Parses without checking the signature. Only for deriving the key while
  /// joining, before the current owner is known; see `SecureChannel`.
  factory ChannelMeta.parseUnverified(Uint8List data) {
    final r = ByteReader(data);
    r.bytes(Identity.signatureBytes);
    return ChannelMeta.fromJson(decodeJson(r.rest()));
  }

  static bool verifies(PepCrypto c, {required String topic, required Uint8List data, required Uint8List ownerKey}) {
    if (data.length < Identity.signatureBytes) return false;
    final sig = Uint8List.sublistView(data, 0, Identity.signatureBytes);
    final json = Uint8List.sublistView(data, Identity.signatureBytes);
    return Identity.verify(c, _toSign(topic, json), sig, ownerKey);
  }

  static const version = 1;

  final KdfParams kdf;
  final Uint8List keyCheck;

  /// Increases with every password change; older revisions are ignored.
  final int rev;

  Json toJson() => {'v': version, 'kdf': kdf.toJson(), 'check': b64u(keyCheck), 'rev': rev};

  Uint8List seal({required String topic, required Identity owner}) {
    final json = encodeJson(toJson());
    return (ByteWriter()
          ..bytes(owner.sign(_toSign(topic, json)))
          ..bytes(json))
        .take();
  }

  static Uint8List _toSign(String topic, Uint8List json) =>
      (ByteWriter()
            ..bytes(utf8Bytes('pep-meta-v1'))
            ..lp16(utf8Bytes(topic))
            ..bytes(json))
          .take();
}
