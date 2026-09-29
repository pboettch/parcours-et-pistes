import 'package:flutter/material.dart';
import 'package:pep_core/pep_core.dart';
import 'package:url_launcher/url_launcher.dart';

import '../state/app_state.dart';
import '../util.dart';

/// The selected track, at the bottom of the map.
class TrackCard extends StatelessWidget {
  const TrackCard({super.key, required this.app, required this.track});

  final AppState app;
  final Track track;

  @override
  Widget build(BuildContext context) {
    final trail = track.trail;
    final objects = track.document.objects.length;
    final length = track.line?.length ?? 0;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 4, 8),
        child: Row(
          children: [
            LevelBadge(track),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    track.title,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    [
                      metres(length),
                      if (objects > 0) '$objects objets',
                      if (trail?.setter != null) 'poseur : ${trail!.setter}',
                    ].join(' · '),
                    style: Theme.of(context).textTheme.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Détails',
              icon: const Icon(Icons.description_outlined),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => TrackDetails(app: app, trackId: track.id),
                ),
              ),
            ),
            IconButton(tooltip: 'Fermer', icon: const Icon(Icons.close), onPressed: () => app.selectTrack(null)),
          ],
        ),
      ),
    );
  }
}

/// Everything about a track: places (with navigation), objects, and the
/// official trail sheet (placeholder).
class TrackDetails extends StatelessWidget {
  const TrackDetails({super.key, required this.app, required this.trackId});

  final AppState app;
  final String trackId;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) {
      final t = app.session?.tracks[trackId];
      if (t == null) {
        return Scaffold(
          appBar: AppBar(),
          body: const Center(child: Text('Parcours supprimé')),
        );
      }
      final trail = t.trail;
      final pts = t.points;
      return Scaffold(
        appBar: AppBar(title: Text(t.title)),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Row(
              children: [
                LevelBadge(t),
                const SizedBox(width: 12),
                Expanded(child: Text([metres(t.line?.length ?? 0), '${t.document.objects.length} objets'].join(' · '))),
              ],
            ),
            if (trail?.setter != null)
              Padding(padding: const EdgeInsets.only(top: 8), child: Text('Poseur : ${trail!.setter}')),
            if (t.document.description != null)
              Padding(padding: const EdgeInsets.only(top: 8), child: Text(t.document.description!)),
            const SizedBox(height: 16),
            Text('Lieux', style: Theme.of(context).textTheme.titleMedium),
            for (final p in t.document.places) _PlaceTile(p.name ?? 'Lieu', p.description, p),
            if (pts.isNotEmpty) ...[_PlaceTile('Départ', null, pts.first), _PlaceTile('Arrivée', null, pts.last)],
            const SizedBox(height: 16),
            Text('Objets', style: Theme.of(context).textTheme.titleMedium),
            for (final (i, o) in t.document.objects.indexed)
              ListTile(
                dense: true,
                leading: CircleAvatar(radius: 12, backgroundColor: Colors.orange.shade800, child: Text('${i + 1}')),
                title: Text(o.name ?? 'Objet ${i + 1}'),
                subtitle: o.description == null ? null : Text(o.description!),
              ),
            const SizedBox(height: 16),
            Card(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: const ListTile(
                leading: Icon(Icons.assignment_outlined),
                title: Text('Fiche officielle (description de pose)'),
                subtitle: Text(
                  'À venir : partie organisateurs (heures de pose et de prise de piste, aire de départ, '
                  'lieux de pose et nature des objets…) et partie juge (conditions, rencontres, observations), '
                  'enregistrées dans le GPX ; génération des documents à imprimer.',
                ),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(Icons.map),
              label: const Text('Voir sur la carte'),
              onPressed: () {
                app.selectTrack(t.id);
                Navigator.of(context).popUntil((r) => r.isFirst);
              },
            ),
          ],
        ),
      );
    },
  );
}

class _PlaceTile extends StatelessWidget {
  const _PlaceTile(this.label, this.description, this.point);

  final String label;
  final String? description;
  final GeoPoint point;

  @override
  Widget build(BuildContext context) => ListTile(
    dense: true,
    contentPadding: EdgeInsets.zero,
    leading: const Icon(Icons.place_outlined),
    title: Text(label),
    subtitle: description == null ? null : Text(description!),
    trailing: Wrap(
      spacing: 4,
      children: [
        OutlinedButton(
          onPressed: () => launchUrl(Uri.parse('https://www.google.com/maps?q=${point.lat},${point.lon}')),
          child: const Text('Maps'),
        ),
        OutlinedButton(
          onPressed: () => launchUrl(Uri.parse('https://ul.waze.com/ul?ll=${point.lat},${point.lon}&navigate=yes')),
          child: const Text('Waze'),
        ),
      ],
    ),
  );
}

/// The selected run: dog, progress, distance to the track, position source.
class RunCard extends StatelessWidget {
  const RunCard({super.key, required this.app, required this.runId});

  final AppState app;
  final String runId;

  @override
  Widget build(BuildContext context) {
    final s = app.session!;
    final run = s.runs[runId]!;
    final progress = s.runProgress(runId);
    final path = s.dogPath(runId);
    final source = run.source;
    final live = source == null ? null : s.positions[source];
    final GeoPoint? dog = live ?? (path.isEmpty ? null : path.last);
    final line = s.tracks[run.track]?.line;
    final dist = dog == null || line == null ? null : line.nearest(dog.lat, dog.lon).distance;
    final status = switch (run.status) {
      RunStatus.planned => 'prévu',
      RunStatus.running => 'en cours',
      RunStatus.finished => 'terminé',
    };
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 4, 8),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: Colors.red.shade700,
              child: const Icon(Icons.pets, color: Colors.white),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${run.dog}${run.handler == null ? '' : ' · ${run.handler}'} — $status',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    [
                      if (progress == null)
                        'parcours inconnu'
                      else if (progress.started)
                        '${(progress.fraction * 100).round()} % du parcours'
                      else
                        'départ non détecté',
                      if (dist != null) 'à ${metres(dist)} du tracé',
                      source == null ? 'pas de position désignée' : 'position : ${memberName(s, source, app: app)}',
                      if (live != null) ago(live.time),
                    ].join(' · '),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (progress != null && progress.started)
                    Padding(
                      padding: const EdgeInsets.only(top: 4, right: 8),
                      child: LinearProgressIndicator(value: progress.fraction, color: Colors.red),
                    ),
                ],
              ),
            ),
            IconButton(tooltip: 'Fermer', icon: const Icon(Icons.close), onPressed: () => app.selectRun(null)),
          ],
        ),
      ),
    );
  }
}
