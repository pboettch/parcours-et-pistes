import 'dart:typed_data';

import 'package:sodium/sodium_sumo.dart';

import '../codec/bytes.dart';
import '../codec/compression.dart';
import '../errors.dart';
import 'identity.dart';
import 'pep_crypto.dart';

/// Content of an opened envelope (signature already verified).
class Opened {
  Opened({required this.signer, required this.rev, required this.time, required this.deleted, required this.body});

  /// Public key of the member who signed the payload.
  final Uint8List signer;

  /// Revision of the item; newer revisions replace older ones.
  final int rev;

  /// Publish time chosen by the signer.
  final DateTime time;

  /// Tombstone: the item was deleted (empty body).
  final bool deleted;

  /// Decompressed body (opaque to the channel).
  final Uint8List body;

  String get signerId => b64u(signer);
}

/// Sealed payload format (every MQTT payload except `meta`):
///
/// ```text
/// "PEP1" | version u8 | nonce[24] | XChaCha20-Poly1305(key, ad = topic, plaintext)
/// plaintext = header | signer public key[32] | signature[64] | body
/// header    = flags u8 (bit0 deflated, bit1 deleted) | rev u32 | time u64 (ms, UTC)
/// signature = Ed25519("pep-sig-v1" | lp16(topic) | header | body)
/// ```
///
/// Binding the topic both as AEAD associated data and into the signature
/// prevents replaying a payload under another topic or project. The signed
/// header lets the channel order, delete and expire items without looking at
/// their (opaque) body.
class Envelope {
  Envelope(this._c);

  final PepCrypto _c;

  static final _magic = Uint8List.fromList('PEP1'.codeUnits);
  static const version = 1;
  static const _flagDeflated = 0x01;
  static const _flagDeleted = 0x02;
  static const maxRev = 0xffffffff;
  static const _nonceBytes = 24;

  Uint8List seal({
    required SecureKey key,
    required String topic,
    required Uint8List body,
    required Identity signer,
    required int rev,
    required DateTime time,
    bool deleted = false,
    bool compress = true,
  }) {
    if (rev < 0 || rev > maxRev) throw ArgumentError.value(rev, 'rev');
    var flags = deleted ? _flagDeleted : 0;
    var payload = body;
    if (compress && body.length > 64) {
      final z = deflate(body);
      if (z.length < body.length) {
        payload = z;
        flags |= _flagDeflated;
      }
    }
    final header = _header(flags, rev, time.millisecondsSinceEpoch);
    final sig = signer.sign(_toSign(topic, header, payload));
    final plain = (ByteWriter()
          ..bytes(header)
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
    final header = p.bytes(_headerBytes);
    final signer = Uint8List.fromList(p.bytes(Identity.publicKeyBytes));
    final sig = p.bytes(Identity.signatureBytes);
    final payload = p.rest();
    if (!Identity.verify(_c, _toSign(topic, header, payload), sig, signer)) {
      throw const AuthorizationException('invalid signature');
    }
    final h = ByteReader(header);
    final flags = h.u8();
    final rev = h.u32();
    final ms = h.u32() * 0x100000000 + h.u32();
    final deleted = (flags & _flagDeleted) != 0;
    final body = (flags & _flagDeflated) != 0 ? inflate(payload) : Uint8List.fromList(payload);
    if (deleted && body.isNotEmpty) throw const FormatPepException('tombstone with a body');
    return Opened(
      signer: signer,
      rev: rev,
      time: DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true),
      deleted: deleted,
      body: body,
    );
  }

  static const _headerBytes = 1 + 4 + 8;

  static Uint8List _header(int flags, int rev, int ms) {
    if (ms < 0) throw ArgumentError.value(ms, 'time');
    return (ByteWriter()
          ..u8(flags)
          ..u32(rev)
          // Split, not >>: bit shifts are 32-bit when compiled to JS.
          ..u32(ms ~/ 0x100000000)
          ..u32(ms % 0x100000000))
        .take();
  }

  static Uint8List _toSign(String topic, Uint8List header, Uint8List payload) => (ByteWriter()
        ..bytes(utf8Bytes('pep-sig-v1'))
        ..lp16(utf8Bytes(topic))
        ..bytes(header)
        ..bytes(payload))
      .take();
}
