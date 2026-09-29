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
    final r = ByteReader(data);
    final sig = r.bytes(Identity.signatureBytes);
    final json = r.rest();
    if (!Identity.verify(c, _toSign(topic, json), sig, ownerKey)) {
      throw const AuthorizationException('meta not signed by the channel owner');
    }
    return ChannelMeta.fromJson(decodeJson(json));
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
