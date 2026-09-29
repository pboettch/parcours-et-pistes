import 'dart:typed_data';

import 'package:sodium/sodium_sumo.dart';

import '../codec/bytes.dart';
import '../codec/compression.dart';
import '../errors.dart';
import 'identity.dart';
import 'pep_crypto.dart';

/// Content of an opened envelope.
class Opened {
  Opened(this.signer, this.body);

  /// Public key of the member who signed the payload (signature already verified).
  final Uint8List signer;

  /// Decompressed body.
  final Uint8List body;

  String get signerId => b64u(signer);
}

/// Sealed payload format (every MQTT payload except `meta`):
///
/// ```text
/// "PEP1" | version u8 | nonce[24] | XChaCha20-Poly1305(key, ad = topic, plaintext)
/// plaintext = flags u8 | signer public key[32] | signature[64] | body
/// signature = Ed25519("pep-sig-v1" | lp16(topic) | flags | body)
/// ```
///
/// Binding the topic both as AEAD associated data and into the signature
/// prevents replaying a payload under another topic or project.
class Envelope {
  Envelope(this._c);

  final PepCrypto _c;

  static final _magic = Uint8List.fromList('PEP1'.codeUnits);
  static const version = 1;
  static const _flagDeflated = 0x01;
  static const _nonceBytes = 24;

  Uint8List seal({
    required SecureKey key,
    required String topic,
    required Uint8List body,
    required Identity signer,
    bool compress = true,
  }) {
    var flags = 0;
    var payload = body;
    if (compress && body.length > 64) {
      final z = deflate(body);
      if (z.length < body.length) {
        payload = z;
        flags |= _flagDeflated;
      }
    }
    final sig = signer.sign(_toSign(topic, flags, payload));
    final plain = (ByteWriter()
          ..u8(flags)
          ..bytes(signer.publicKey)
          ..bytes(sig)
          ..bytes(payload))
        .take();
    final nonce = _c.randomBytes(_nonceBytes);
    final ct = _c.sodium.crypto.aeadXChaCha20Poly1305IETF
        .encrypt(message: plain, nonce: nonce, key: key, additionalData: utf8Bytes(topic));
    return (ByteWriter()
          ..bytes(_magic)
          ..u8(version)
          ..bytes(nonce)
          ..bytes(ct))
        .take();
  }

  /// Decrypts, verifies the signature and decompresses. Authorization (is this
  /// signer allowed to publish here?) is the caller's job.
  Opened open({required SecureKey key, required String topic, required Uint8List data}) {
    final r = ByteReader(data);
    if (!bytesEqual(r.bytes(4), _magic)) throw const FormatPepException('not a PEP envelope');
    final v = r.u8();
    if (v != version) throw FormatPepException('unsupported envelope version $v');
    final nonce = r.bytes(_nonceBytes);
    final ct = r.rest();
    final Uint8List plain;
    try {
      plain = _c.sodium.crypto.aeadXChaCha20Poly1305IETF
          .decrypt(cipherText: ct, nonce: nonce, key: key, additionalData: utf8Bytes(topic));
    } catch (_) {
      throw const DecryptionException('cannot decrypt (wrong key, topic or tampered data)');
    }
    final p = ByteReader(plain);
    final flags = p.u8();
    final signer = Uint8List.fromList(p.bytes(Identity.publicKeyBytes));
    final sig = p.bytes(Identity.signatureBytes);
    final payload = p.rest();
    if (!Identity.verify(_c, _toSign(topic, flags, payload), sig, signer)) {
      throw const AuthorizationException('invalid signature');
    }
    final body = (flags & _flagDeflated) != 0 ? inflate(payload) : Uint8List.fromList(payload);
    return Opened(signer, body);
  }

  static Uint8List _toSign(String topic, int flags, Uint8List payload) => (ByteWriter()
        ..bytes(utf8Bytes('pep-sig-v1'))
        ..lp16(utf8Bytes(topic))
        ..u8(flags)
        ..bytes(payload))
      .take();
}
