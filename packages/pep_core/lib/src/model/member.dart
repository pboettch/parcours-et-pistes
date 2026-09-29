import 'dart:typed_data';

import 'json.dart';

/// Member profile (`member/<id>` topic), signed by the member itself.
class MemberDoc {
  MemberDoc({required this.name, required this.updated});

  factory MemberDoc.fromJson(Json j) {
    j.checkVersion(version);
    return MemberDoc(name: j.req<String>('name'), updated: msToDate(j.req<int>('upd')));
  }

  factory MemberDoc.decode(Uint8List b) => MemberDoc.fromJson(decodeJson(b));

  static const version = 1;

  final String name;
  final DateTime updated;

  Json toJson() => {'v': version, 'name': name, 'upd': updated.millisecondsSinceEpoch};

  Uint8List encode() => encodeJson(toJson());
}
