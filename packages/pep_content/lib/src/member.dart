import 'dart:typed_data';

import 'json.dart';

/// A member's public profile (`member` collection, one item per member).
class MemberProfile {
  MemberProfile({required this.name, this.bot = false, this.extra = const {}});

  factory MemberProfile.fromJson(Json j) {
    j.checkVersion(version);
    return MemberProfile(
      name: j.req<String>('name'),
      bot: j.opt<bool>('bot') ?? false,
      extra: Map.unmodifiable(j.optMap('extra')),
    );
  }

  factory MemberProfile.decode(Uint8List b) => MemberProfile.fromJson(decodeJson(b));

  static const version = 1;

  final String name;

  /// An automated member, e.g. a service feeding a GPS collar's positions.
  final bool bot;

  /// Additional fields (the document's `extra` object), preserved as is on a
  /// round trip. Other unknown fields are dropped.
  final Json extra;

  Json toJson() => {'v': version, 'name': name, if (bot) 'bot': true, if (extra.isNotEmpty) 'extra': extra};

  Uint8List encode() => encodeJson(toJson());
}
