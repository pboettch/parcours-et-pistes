import 'dart:typed_data';

import 'package:sodium/sodium_sumo.dart';

import '../codec/bytes.dart';
import '../errors.dart';
import 'pep_crypto.dart';

/// Password-hashing parameters, stored in plaintext in the project's `meta` topic.
class KdfParams {
  KdfParams({
    required this.opsLimit,
    required this.memLimit,
    required this.salt,
  }) {
    if (opsLimit < minOps || opsLimit > maxOps) {
      throw FormatPepException('kdf opsLimit $opsLimit out of range');
    }
    if (memLimit < minMem || memLimit > maxMem) {
      throw FormatPepException('kdf memLimit $memLimit out of range');
    }
    if (salt.length != saltBytes) {
      throw const FormatPepException('kdf salt must be 16 bytes');
    }
  }

  factory KdfParams.generate(PepCrypto c,
          {int opsLimit = defaultOps, int memLimit = defaultMem}) =>
      KdfParams(opsLimit: opsLimit, memLimit: memLimit, salt: c.randomBytes(saltBytes));

  factory KdfParams.fromJson(Map<String, dynamic> j) {
    if (j['alg'] != alg) throw FormatPepException('unsupported kdf ${j['alg']}');
    return KdfParams(
      opsLimit: _int(j['ops']),
      memLimit: _int(j['mem']),
      salt: unb64u(j['salt'] as String? ?? ''),
    );
  }

  static const alg = 'argon2id13';
  static const saltBytes = 16;

  /// Defaults: ~20 ms on desktop VM, ~75 ms in the browser (2026 hardware).
  static const defaultOps = 3;
  static const defaultMem = 64 * 1024 * 1024;

  /// Bounds applied to untrusted params read from the broker (DoS protection).
  static const minOps = 1, maxOps = 10;
  static const minMem = 8 * 1024 * 1024, maxMem = 256 * 1024 * 1024;

  final int opsLimit;
  final int memLimit;
  final Uint8List salt;

  Map<String, dynamic> toJson() =>
      {'alg': alg, 'ops': opsLimit, 'mem': memLimit, 'salt': b64u(salt)};

  static int _int(Object? v) =>
      v is int ? v : throw const FormatPepException('kdf param is not an integer');
}

/// Keys derived from a project password. Call [dispose] when no longer needed.
class ProjectKey {
  ProjectKey._(this.dataKey, this.check);

  /// Derives the project keys from [password]. CPU/memory intensive: run it off
  /// the UI thread in apps.
  factory ProjectKey.derive(PepCrypto c, String password, KdfParams p) {
    if (password.isEmpty) throw const FormatPepException('empty password');
    final s = c.sodium;
    final master = s.crypto.pwhash.callStr(
      outLen: s.crypto.kdf.keyBytes,
      password: password,
      salt: p.salt,
      opsLimit: p.opsLimit,
      memLimit: p.memLimit,
      alg: CryptoPwhashAlgorithm.argon2id13,
    );
    try {
      final data = s.crypto.kdf.deriveFromKey(
          masterKey: master, context: _context, subkeyId: BigInt.one, subkeyLen: 32);
      final checkKey = s.crypto.kdf.deriveFromKey(
          masterKey: master, context: _context, subkeyId: BigInt.two, subkeyLen: 32);
      final check = s.crypto.genericHash(
          message: utf8Bytes('pep-key-check'), key: checkKey, outLen: 16);
      checkKey.dispose();
      return ProjectKey._(data, check);
    } finally {
      master.dispose();
    }
  }

  static const _context = 'PEPv1key';

  /// AEAD key for all sealed payloads of the project.
  final SecureKey dataKey;

  /// Public key-check value stored in `meta`, used to report a wrong password
  /// immediately (it gives an attacker nothing beyond what any ciphertext gives).
  final Uint8List check;

  void dispose() => dataKey.dispose();
}
