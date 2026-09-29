import 'dart:typed_data';

import 'json.dart';
import 'project_doc.dart';

/// A track (`track/<id>` topic), published by the owner or an editor.
///
/// Deleting a track publishes a signed tombstone ([deleted] = true, no GPX), so
/// the deletion is authenticated like any other update.
class TrackDoc {
  TrackDoc({
    required this.id,
    required this.rev,
    required this.updated,
    this.name,
    this.discipline,
    this.gpx,
    this.notes,
    this.deleted = false,
    this.extra = const {},
  }) : assert(deleted || gpx != null, 'a live track needs GPX');

  factory TrackDoc.tombstone(String id, {required int rev, DateTime? now}) =>
      TrackDoc(id: id, rev: rev, updated: (now ?? DateTime.now()).toUtc(), deleted: true);

  factory TrackDoc.fromJson(Json j) {
    j.checkVersion(version);
    final deleted = j.opt<bool>('deleted') ?? false;
    final disc = j.opt<String>('disc');
    return TrackDoc(
      id: j.req<String>('id'),
      rev: j.req<int>('rev'),
      updated: msToDate(j.req<int>('upd')),
      deleted: deleted,
      name: j.opt<String>('name'),
      discipline: disc == null ? null : Discipline.parse(disc),
      gpx: deleted ? null : j.req<String>('gpx'),
      notes: j.opt<String>('notes'),
      extra: Map.unmodifiable(j.optMap('extra')),
    );
  }

  factory TrackDoc.decode(Uint8List b) => TrackDoc.fromJson(decodeJson(b));

  static const version = 1;

  final String id;

  /// Increases with every update of this track; older revisions are ignored.
  final int rev;
  final DateTime updated;
  final String? name;
  final Discipline? discipline;

  /// GPX 1.1 document (see `Gpx` for parsing). Null for tombstones.
  final String? gpx;
  final String? notes;
  final bool deleted;

  /// Additional information (RU details to be specified), preserved on round trip.
  final Json extra;

  Json toJson() => {
        'v': version,
        'id': id,
        'rev': rev,
        'upd': updated.millisecondsSinceEpoch,
        if (deleted) 'deleted': true,
        if (name != null) 'name': name,
        if (discipline != null) 'disc': discipline!.name,
        if (gpx != null) 'gpx': gpx,
        if (notes != null) 'notes': notes,
        if (extra.isNotEmpty) 'extra': extra,
      };

  Uint8List encode() => encodeJson(toJson());
}
