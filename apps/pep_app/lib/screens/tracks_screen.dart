import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../util.dart';
import 'track_sheet.dart';

/// The project's tracks, as cards (like the CCO overview page).
class TracksScreen extends StatelessWidget {
  const TracksScreen({super.key, required this.app});

  final AppState app;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) {
      final tracks = app.session?.tracks.values.toList() ?? [];
      tracks.sort((a, b) => a.title.compareTo(b.title));
      return Scaffold(
        appBar: AppBar(title: const Text('Parcours')),
        body: tracks.isEmpty
            ? const Center(child: Text('Aucun parcours'))
            : ListView(
                padding: const EdgeInsets.all(8),
                children: [
                  for (final t in tracks)
                    Card(
                      child: ListTile(
                        leading: SizedBox(width: 64, child: Center(child: LevelBadge(t))),
                        title: Text(t.title),
                        subtitle: Text(
                          [
                            metres(t.line?.length ?? 0),
                            '${t.document.objects.length} objets',
                            if (t.trail?.setter != null) 'poseur : ${t.trail!.setter}',
                          ].join(' · '),
                        ),
                        selected: t.id == app.selectedTrackId,
                        onTap: () {
                          app.selectTrack(t.id);
                          Navigator.of(context).pop();
                        },
                        trailing: IconButton(
                          tooltip: 'Détails',
                          icon: const Icon(Icons.description_outlined),
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => TrackDetails(app: app, trackId: t.id),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
      );
    },
  );
}
