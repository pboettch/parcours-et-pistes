import 'package:pep_channel/pep_channel.dart';

PepCrypto? _crypto;

/// One libsodium instance per test isolate.
Future<PepCrypto> testCrypto() async => _crypto ??= await PepCrypto.init();

/// Cheap KDF params so tests stay fast.
KdfParams fastKdf(PepCrypto c) => KdfParams.generate(c, opsLimit: KdfParams.minOps, memLimit: KdfParams.minMem);
