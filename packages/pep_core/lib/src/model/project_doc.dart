import 'dart:typed_data';

import '../crypto/identity.dart';
import '../errors.dart';
import 'json.dart';

enum Discipline {
  /// Recherche Utilitaire: track plus object positions.
  ru,

  /// Man Trailing: track only.
  mt;

  static Discipline parse(String s) => Discipline.values.firstWhere((d) => d.name == s,
      orElse: () => throw FormatPepException('unknown discipline "$s"'));
}

class ProjectSettings {
  const ProjectSettings({this.positionTtl = defaultPositionTtl, this.extra = const {}});

  factory ProjectSettings.fromJson(Json j) {
    final ttl = j.opt<int>('posTtl') ?? defaultPositionTtl.inSeconds;
    if (ttl < 10 || ttl > 7 * 24 * 3600) throw FormatPepException('position ttl $ttl out of range');
    return ProjectSettings(
      positionTtl: Duration(seconds: ttl),
      extra: Map.unmodifiable(Map<String, dynamic>.from(j)..remove('posTtl')),
    );
  }

  static const defaultPositionTtl = Duration(minutes: 30);

  /// How long a shared position stays visible after its last update.
  final Duration positionTtl;

  /// Settings unknown to this library version, preserved on round trip.
  final Json extra;

  ProjectSettings copyWith({Duration? positionTtl, Json? extra}) =>
      ProjectSettings(positionTtl: positionTtl ?? this.positionTtl, extra: extra ?? this.extra);

  Json toJson() => {...extra, 'posTtl': positionTtl.inSeconds};
}

/// Owner-signed project document (`project` topic).
class ProjectDoc {
  ProjectDoc({
    required this.id,
    required this.name,
    required this.discipline,
    required this.ownerId,
    this.editors = const {},
    this.settings = const ProjectSettings(),
    required this.rev,
    required this.updated,
    this.description,
  }) {
    publicKeyFromId(ownerId);
    editors.forEach(publicKeyFromId);
  }

  factory ProjectDoc.fromJson(Json j) {
    j.checkVersion(version);
    return ProjectDoc(
      id: j.req<String>('id'),
      name: j.req<String>('name'),
      description: j.opt<String>('desc'),
      discipline: Discipline.parse(j.req<String>('disc')),
      ownerId: j.req<String>('owner'),
      editors: Set.unmodifiable(j.strList('editors')),
      settings: ProjectSettings.fromJson(j.optMap('settings')),
      rev: j.req<int>('rev'),
      updated: msToDate(j.req<int>('upd')),
    );
  }

  factory ProjectDoc.decode(Uint8List b) => ProjectDoc.fromJson(decodeJson(b));

  static const version = 1;

  final String id;
  final String name;
  final String? description;
  final Discipline discipline;
  final String ownerId;

  /// Members (ids) allowed to publish and delete tracks besides the owner.
  final Set<String> editors;
  final ProjectSettings settings;

  /// Increases with every update; older revisions are ignored (rollback protection).
  final int rev;
  final DateTime updated;

  bool canEditTracks(String memberId) => memberId == ownerId || editors.contains(memberId);

  ProjectDoc next({
    String? name,
    String? description,
    Set<String>? editors,
    ProjectSettings? settings,
    DateTime? now,
  }) =>
      ProjectDoc(
        id: id,
        name: name ?? this.name,
        description: description ?? this.description,
        discipline: discipline,
        ownerId: ownerId,
        editors: Set.unmodifiable(editors ?? this.editors),
        settings: settings ?? this.settings,
        rev: rev + 1,
        updated: (now ?? DateTime.now()).toUtc(),
      );

  Json toJson() => {
        'v': version,
        'id': id,
        'name': name,
        if (description != null) 'desc': description,
        'disc': discipline.name,
        'owner': ownerId,
        'editors': editors.toList()..sort(),
        'settings': settings.toJson(),
        'rev': rev,
        'upd': updated.millisecondsSinceEpoch,
      };

  Uint8List encode() => encodeJson(toJson());
}
