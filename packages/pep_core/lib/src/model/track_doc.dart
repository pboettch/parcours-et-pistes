import 'dart:typed_data';

import 'gpx.dart';
import 'json.dart';

/// A track (`track/<id>` topic), published by the owner or an editor.
///
/// Everything describing the track — name, description, the trail itself, RU
/// objects (waypoints) and any additional information (custom `<extensions>`
/// sections in the `pep` namespace) — is carried by the GPX document. This
/// wrapper only adds what the protocol needs: id, revision, timestamp.
///
/// Deleting a track publishes a signed tombstone ([deleted] = true, no GPX), so
/// the deletion is authenticated like any other update.
class TrackDoc {
  TrackDoc({required this.id, required this.rev, required this.updated, this.gpx, this.deleted = false})
      : assert(deleted || gpx != null, 'a live track needs GPX');

  factory TrackDoc.tombstone(String id, {required int rev, DateTime? now}) =>
      TrackDoc(id: id, rev: rev, updated: (now ?? DateTime.now()).toUtc(), deleted: true);

  factory TrackDoc.fromJson(Json j) {
    j.checkVersion(version);
    final deleted = j.opt<bool>('deleted') ?? false;
    return TrackDoc(
      id: j.req<String>('id'),
      rev: j.req<int>('rev'),
      updated: msToDate(j.req<int>('upd')),
      deleted: deleted,
      gpx: deleted ? null : j.req<String>('gpx'),
    );
  }

  factory TrackDoc.decode(Uint8List b) => TrackDoc.fromJson(decodeJson(b));

  static const version = 1;

  final String id;

  /// Increases with every update of this track; older revisions are ignored.
  final int rev;
  final DateTime updated;

  /// GPX 1.1 document. Null for tombstones.
  final String? gpx;
  final bool deleted;

  /// The parsed [gpx] (parsed once, on first access).
  late final Gpx document = Gpx.parse(gpx ?? (throw StateError('tombstone has no GPX')));

  /// Display name: GPX metadata name, else the first track's name.
  String? get name => document.name ?? document.tracks.firstOrNull?.name;

  Json toJson() => {
        'v': version,
        'id': id,
        'rev': rev,
        'upd': updated.millisecondsSinceEpoch,
        if (deleted) 'deleted': true,
        if (gpx != null) 'gpx': gpx,
      };

  Uint8List encode() => encodeJson(toJson());
}
