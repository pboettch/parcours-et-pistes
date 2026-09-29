import '../crypto/pep_crypto.dart';
import '../errors.dart';

final _uuidRe = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');
final _levelRe = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

/// Random UUID v4 from libsodium's CSPRNG. Project ids are secrets: they are the
/// only thing protecting a project's (encrypted) topics from being found.
String newUuid(PepCrypto c) {
  final b = c.randomBytes(16);
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}

bool isProjectId(String s) => _uuidRe.hasMatch(s);

/// Track and member ids: safe as a single MQTT topic level.
bool isTopicId(String s) => _levelRe.hasMatch(s);

String checkProjectId(String s) =>
    isProjectId(s) ? s : throw FormatPepException('invalid project id "$s"');

String checkTopicId(String s) => isTopicId(s) ? s : throw FormatPepException('invalid id "$s"');
