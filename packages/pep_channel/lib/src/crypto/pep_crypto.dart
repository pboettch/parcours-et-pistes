import 'dart:typed_data';

import 'package:sodium/sodium_sumo.dart';

/// Entry point to the cryptographic backend (libsodium, sumo variant).
///
/// Obtain one with [PepCrypto.init] (pure Dart / tests), or wrap the instance
/// returned by `SodiumSumoInit.init()` of the `sodium_libs` Flutter plugin.
class PepCrypto {
  PepCrypto(this.sodium);

  final SodiumSumo sodium;

  static Future<PepCrypto> init() async => PepCrypto(await SodiumSumoInit.init());

  Uint8List randomBytes(int n) => sodium.randombytes.buf(n);
}
