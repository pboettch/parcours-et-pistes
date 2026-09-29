import 'dart:typed_data';

import 'json.dart';

/// A member's public profile (`member` collection, one item per member).
class MemberProfile {
  MemberProfile({required this.name});

  factory MemberProfile.fromJson(Json j) {
    j.checkVersion(version);
    return MemberProfile(name: j.req<String>('name'));
  }

  factory MemberProfile.decode(Uint8List b) => MemberProfile.fromJson(decodeJson(b));

  static const version = 1;

  final String name;

  Json toJson() => {'v': version, 'name': name};

  Uint8List encode() => encodeJson(toJson());
}
