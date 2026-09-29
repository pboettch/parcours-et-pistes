import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:sodium/sodium_sumo.dart';

import '../codec/bytes.dart';
import '../errors.dart';
import 'pep_crypto.dart';

/// A device's Ed25519 signing identity. There is no central user database:
/// members are identified by their public key.
class Identity {
  Identity._(this._c, this._keyPair);

  factory Identity.generate(PepCrypto c) => Identity._(c, c.sodium.crypto.sign.keyPair());

  /// Restores an identity from its 32-byte seed (see [exportSeed]).
  factory Identity.fromSeed(PepCrypto c, Uint8List seed) {
    final sign = c.sodium.crypto.sign;
    if (seed.length != sign.seedBytes) throw const FormatPepException('invalid seed');
    final sk = c.sodium.secureCopy(seed);
    try {
      return Identity._(c, sign.seedKeyPair(sk));
    } finally {
      sk.dispose();
    }
  }

  static const publicKeyBytes = 32;
  static const signatureBytes = 64;

  final PepCrypto _c;
  final KeyPair _keyPair;

  Uint8List get publicKey => _keyPair.publicKey;

  /// Stable member id: unpadded base64url of the public key (43 chars, topic-safe).
  String get id => b64u(publicKey);

  /// The secret seed. Store it in the platform's secure storage.
  Uint8List exportSeed() {
    final seed = _c.sodium.crypto.sign.skToSeed(_keyPair.secretKey);
    try {
      return seed.extractBytes();
    } finally {
      seed.dispose();
    }
  }

  Uint8List sign(Uint8List message) => _c.sodium.crypto.sign.detached(message: message, secretKey: _keyPair.secretKey);

  static bool verify(PepCrypto c, Uint8List message, Uint8List signature, Uint8List publicKey) {
    if (signature.length != signatureBytes || publicKey.length != publicKeyBytes) return false;
    try {
      return c.sodium.crypto.sign.verifyDetached(message: message, signature: signature, publicKey: publicKey);
    } catch (_) {
      return false;
    }
  }

  /// Human-comparable fingerprint of this identity (see [fingerprintOf]).
  String get fingerprint => fingerprintOf(id);

  /// Encrypts [message] so that only [recipientId] can read it (libsodium
  /// sealed box to the X25519 form of the recipient's Ed25519 key).
  static Uint8List sealFor(PepCrypto c, String recipientId, Uint8List message) => c.sodium.crypto.box.seal(
    message: message,
    publicKey: c.sodium.crypto.sign.pkToCurve25519(publicKeyFromId(recipientId)),
  );

  /// Opens a [sealFor] message addressed to this identity; null if it is not
  /// for us or was tampered with.
  Uint8List? openSealed(Uint8List sealed) {
    final sign = _c.sodium.crypto.sign;
    final sk = sign.skToCurve25519(_keyPair.secretKey);
    try {
      return _c.sodium.crypto.box.sealOpen(
        cipherText: sealed,
        publicKey: sign.pkToCurve25519(publicKey),
        secretKey: sk,
      );
    } catch (_) {
      return null;
    } finally {
      sk.dispose();
    }
  }

  void dispose() => _keyPair.secretKey.dispose();
}

/// Short fingerprint of a member id for people to compare (e.g. when adding a
/// friend): 80 bits of SHA-256 of the public key, as 4 groups of 4 Crockford
/// base32 characters, e.g. `7K2M-9QXD-4HNR-T0VC`.
String fingerprintOf(String memberId) {
  final digest = hash.sha256.convert(publicKeyFromId(memberId)).bytes;
  const alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  var bits = 0, value = 0;
  final out = StringBuffer();
  for (final b in digest.take(10)) {
    value = (value << 8 | b) & 0xffff;
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      out.write(alphabet[(value >> bits) & 31]);
    }
  }
  final s = out.toString();
  return [for (var i = 0; i < 16; i += 4) s.substring(i, i + 4)].join('-');
}

/// Parses a member id back into a public key.
Uint8List publicKeyFromId(String id) {
  final pk = unb64u(id);
  if (pk.length != Identity.publicKeyBytes) throw const FormatPepException('invalid member id');
  return pk;
}
