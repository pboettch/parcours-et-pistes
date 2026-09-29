import 'dart:typed_data';

import '../codec/bytes.dart';
import '../crypto/kdf.dart';
import 'json.dart';

/// Plaintext `meta` document: everything needed to derive the project key.
/// Contains no names or other project information.
class ProjectMeta {
  ProjectMeta({required this.kdf, required this.keyCheck});

  factory ProjectMeta.fromJson(Json j) {
    j.checkVersion(version);
    return ProjectMeta(kdf: KdfParams.fromJson(j.req<Json>('kdf')), keyCheck: unb64u(j.req<String>('check')));
  }

  factory ProjectMeta.decode(Uint8List b) => ProjectMeta.fromJson(decodeJson(b));

  static const version = 1;

  final KdfParams kdf;
  final Uint8List keyCheck;

  Json toJson() => {'v': version, 'kdf': kdf.toJson(), 'check': b64u(keyCheck)};

  Uint8List encode() => encodeJson(toJson());
}
