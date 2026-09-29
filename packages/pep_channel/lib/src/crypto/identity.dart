import 'dart:typed_data';

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

  void dispose() => _keyPair.secretKey.dispose();
}

/// Parses a member id back into a public key.
Uint8List publicKeyFromId(String id) {
  final pk = unb64u(id);
  if (pk.length != Identity.publicKeyBytes) throw const FormatPepException('invalid member id');
  return pk;
}
