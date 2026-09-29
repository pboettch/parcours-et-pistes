import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:pep_core/pep_core.dart';

import 'state/app_state.dart';

LatLng ll(GeoPoint p) => LatLng(p.lat, p.lon);

/// "il y a 3 min"
String ago(DateTime t, [DateTime? now]) {
  final d = (now ?? DateTime.now()).difference(t);
  if (d.inSeconds < 60) return 'il y a ${d.inSeconds.clamp(0, 59)} s';
  if (d.inMinutes < 60) return 'il y a ${d.inMinutes} min';
  if (d.inHours < 24) return 'il y a ${d.inHours} h';
  return 'il y a ${d.inDays} j';
}

String metres(double m) => m < 1000 ? '${m.round()} m' : '${(m / 1000).toStringAsFixed(2)} km';

/// Display name of a member: their published name, else the start of their id.
String memberName(ProjectSession s, String id, {AppState? app}) {
  if (id == s.memberId) return app?.displayName.isNotEmpty ?? false ? '${app!.displayName} (moi)' : 'Moi';
  return s.members[id]?.name ?? id.substring(0, 8);
}

/// Colour of an RU level badge (as on the CCO site).
Color levelColor(String? level) => switch (level) {
  'B' => const Color(0xFF2E7D32),
  'I' => const Color(0xFF1565C0),
  'II' => const Color(0xFFEF6C00),
  'III' => const Color(0xFFC62828),
  _ => const Color(0xFF546E7A),
};

/// Everything the app shows about a track.
extension TrackView on Track {
  TrailInfo? get trail => TrailInfo.of(document);

  List<GpxPoint> get points => document.tracks.expand((t) => t.points).toList();

  TrackLine? get line => points.isEmpty ? null : TrackLine(points);

  String get title => name ?? id;

  String get badge {
    final t = trail;
    if (t == null) return '';
    return [t.code, t.level].nonNulls.join(' · ');
  }
}

class LevelBadge extends StatelessWidget {
  const LevelBadge(this.track, {super.key});

  final Track track;

  @override
  Widget build(BuildContext context) {
    final b = track.badge;
    if (b.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: levelColor(track.trail?.level), borderRadius: BorderRadius.circular(8)),
      child: Text(
        b,
        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
      ),
    );
  }
}

void showError(BuildContext context, String message) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
