import 'dart:typed_data';

import 'errors.dart';
import 'json.dart';

enum Discipline {
  /// Recherche Utilitaire: track plus object positions.
  ru,

  /// Man Trailing: track only.
  mt;

  static Discipline parse(String s) => Discipline.values.firstWhere(
    (d) => d.name == s,
    orElse: () => throw ContentFormatException('unknown discipline "$s"'),
  );
}

/// Descriptive project information (`info` collection, written by the owner).
/// Access rules and retention live in the channel's ACL, not here.
class ProjectInfo {
  ProjectInfo({required this.name, required this.discipline, this.description, this.extra = const {}});

  factory ProjectInfo.fromJson(Json j) {
    j.checkVersion(version);
    return ProjectInfo(
      name: j.req<String>('name'),
      description: j.opt<String>('desc'),
      discipline: Discipline.parse(j.req<String>('disc')),
      extra: Map.unmodifiable(j.optMap('extra')),
    );
  }

  factory ProjectInfo.decode(Uint8List b) => ProjectInfo.fromJson(decodeJson(b));

  static const version = 1;

  final String name;
  final String? description;
  final Discipline discipline;

  /// Fields unknown to this version, preserved on round trip.
  final Json extra;

  ProjectInfo copyWith({String? name, String? description, Json? extra}) => ProjectInfo(
    name: name ?? this.name,
    description: description ?? this.description,
    discipline: discipline,
    extra: extra ?? this.extra,
  );

  Json toJson() => {
    'v': version,
    'name': name,
    if (description != null) 'desc': description,
    'disc': discipline.name,
    if (extra.isNotEmpty) 'extra': extra,
  };

  Uint8List encode() => encodeJson(toJson());
}
