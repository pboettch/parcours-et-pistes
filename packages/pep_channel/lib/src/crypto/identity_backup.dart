import 'dart:typed_data';

import 'package:sodium/sodium_sumo.dart';

import '../codec/bytes.dart';
import '../errors.dart';
import 'identity.dart';
import 'kdf.dart';
import 'pep_crypto.dart';

/// Password-protected export of an [Identity], to move or copy a user's
/// identity to another device (one identity per user, copied to each of their
/// devices). The result is a short text suitable for a file or a QR code.
///
/// Format: `pepid1.` + base64url(`ops u8 | mem u32 | salt[16] | nonce[24] |
/// XChaCha20-Poly1305(Argon2id(passphrase), ad = "pepid1", seed[32])`).
abstract final class IdentityBackup {
  static const prefix = 'pepid1.';

  static String export(PepCrypto c, Identity identity, String passphrase, {KdfParams? kdf}) {
    final p = kdf ?? KdfParams.generate(c);
    final key = _key(c, passphrase, p);
    try {
      final nonce = c.randomBytes(24);
      final ct = c.sodium.crypto.aeadXChaCha20Poly1305IETF.encrypt(
        message: identity.exportSeed(),
        nonce: nonce,
        key: key,
        additionalData: utf8Bytes(prefix),
      );
      return prefix +
          b64u(
            (ByteWriter()
                  ..u8(p.opsLimit)
                  ..u32(p.memLimit)
                  ..bytes(p.salt)
                  ..bytes(nonce)
                  ..bytes(ct))
                .take(),
          );
    } finally {
      key.dispose();
    }
  }

  /// Throws [WrongPasswordException] for a wrong passphrase (or tampered
  /// backup) and [FormatPepException] for text that is not a backup.
  static Identity import(PepCrypto c, String backup, String passphrase) {
    final text = backup.trim();
    if (!text.startsWith(prefix)) throw const FormatPepException('not an identity backup');
    final r = ByteReader(unb64u(text.substring(prefix.length)));
    final p = KdfParams(opsLimit: r.u8(), memLimit: r.u32(), salt: Uint8List.fromList(r.bytes(KdfParams.saltBytes)));
    final nonce = r.bytes(24);
    final ct = r.rest();
    final key = _key(c, passphrase, p);
    try {
      final seed = c.sodium.crypto.aeadXChaCha20Poly1305IETF.decrypt(
        cipherText: ct,
        nonce: nonce,
        key: key,
        additionalData: utf8Bytes(prefix),
      );
      return Identity.fromSeed(c, seed);
    } on PepException {
      rethrow;
    } catch (_) {
      throw const WrongPasswordException();
    } finally {
      key.dispose();
    }
  }

  static SecureKey _key(PepCrypto c, String passphrase, KdfParams p) {
    if (passphrase.isEmpty) throw const FormatPepException('empty passphrase');
    return c.sodium.crypto.pwhash.callStr(
      outLen: 32,
      password: passphrase,
      salt: p.salt,
      opsLimit: p.opsLimit,
      memLimit: p.memLimit,
      alg: CryptoPwhashAlgorithm.argon2id13,
    );
  }
}
