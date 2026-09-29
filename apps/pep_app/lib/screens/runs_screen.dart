import 'package:flutter/material.dart';
import 'package:pep_core/pep_core.dart';

import '../state/app_state.dart';
import '../util.dart';

/// Dogs working tracks. The leader (owner or editor) creates runs and
/// designates who shares each dog's position.
class RunsScreen extends StatelessWidget {
  const RunsScreen({super.key, required this.app});

  final AppState app;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) {
      final s = app.session;
      if (s == null) return const Scaffold();
      final leader = s.canEditTracks;
      final runs = s.runs.entries.toList()..sort((a, b) => a.value.status.index.compareTo(b.value.status.index));
      return Scaffold(
        appBar: AppBar(title: const Text('Chiens en piste')),
        floatingActionButton: leader && s.tracks.isNotEmpty
            ? FloatingActionButton.extended(
                icon: const Icon(Icons.add),
                label: const Text('Nouveau passage'),
                onPressed: () => _add(context, s),
              )
            : null,
        body: runs.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    leader
                        ? 'Aucun passage. Créez-en un : un chien, un parcours, et le participant qui partage sa position.'
                        : 'Aucun passage pour le moment.',
                  ),
                ),
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 88),
                children: [
                  for (final r in runs) _RunTile(app: app, session: s, id: r.key, run: r.value, leader: leader),
                ],
              ),
      );
    },
  );

  Future<void> _add(BuildContext context, ProjectSession s) async {
    final dog = TextEditingController(), handler = TextEditingController();
    final tracks = s.tracks.values.toList()..sort((a, b) => a.title.compareTo(b.title));
    var track = app.selectedTrackId ?? tracks.first.id;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Nouveau passage'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: track,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Parcours'),
                items: [for (final t in tracks) DropdownMenuItem(value: t.id, child: Text(t.title))],
                onChanged: (v) => setState(() => track = v!),
              ),
              TextField(
                controller: dog,
                decoration: const InputDecoration(labelText: 'Chien'),
              ),
              TextField(
                controller: handler,
                decoration: const InputDecoration(labelText: 'Conducteur'),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Créer')),
          ],
        ),
      ),
    );
    if (ok != true || dog.text.trim().isEmpty) return;
    await app.act((s) async {
      final id = await s.putRun(
        Run(track: track, dog: dog.text.trim(), handler: handler.text.trim().isEmpty ? null : handler.text.trim()),
      );
      app.selectRun(id);
    });
  }
}

class _RunTile extends StatelessWidget {
  const _RunTile({required this.app, required this.session, required this.id, required this.run, required this.leader});

  final AppState app;
  final ProjectSession session;
  final String id;
  final Run run;
  final bool leader;

  @override
  Widget build(BuildContext context) {
    final s = session;
    final progress = s.runProgress(id);
    final track = s.tracks[run.track];
    final (status, color) = switch (run.status) {
      RunStatus.planned => ('prévu', Colors.blueGrey),
      RunStatus.running => ('en cours', Colors.red.shade700),
      RunStatus.finished => ('terminé', Colors.green.shade700),
    };
    final simulating = app.simulator?.runId == id;
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: color,
          child: const Icon(Icons.pets, color: Colors.white),
        ),
        title: Text('${run.dog}${run.handler == null ? '' : ' · ${run.handler}'}'),
        subtitle: Text(
          [
            track?.title ?? 'parcours ${run.track} inconnu',
            status,
            if (progress != null && progress.started) '${(progress.fraction * 100).round()} %',
            run.source == null ? 'position non désignée' : 'position : ${memberName(s, run.source!, app: app)}',
            if (simulating) 'simulation',
          ].join(' · '),
        ),
        selected: id == app.selectedRunId,
        onTap: () {
          app.selectRun(id);
          Navigator.of(context).pop();
        },
        trailing: PopupMenuButton<String>(
          onSelected: (a) => _action(context, a),
          itemBuilder: (_) => [
            if (leader) ...[
              const PopupMenuItem(value: 'source', child: Text('Désigner la position du chien…')),
              if (run.status == RunStatus.planned) const PopupMenuItem(value: 'start', child: Text('Départ')),
              if (run.status == RunStatus.running) const PopupMenuItem(value: 'finish', child: Text('Terminer')),
              const PopupMenuItem(value: 'delete', child: Text('Supprimer')),
            ],
            if (run.status != RunStatus.finished && track != null)
              PopupMenuItem(
                value: simulating ? 'stop-sim' : 'sim',
                child: Text(simulating ? 'Arrêter la simulation' : 'Simuler un chien (test)'),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _action(BuildContext context, String a) async {
    switch (a) {
      case 'source':
        final m = await _pickSource(context);
        if (m != null) await app.act((s) => s.setRunSource(id, m));
      case 'start':
        await app.act((s) => s.startRun(id));
      case 'finish':
        await app.act((s) => s.finishRun(id));
      case 'delete':
        await app.act((s) => s.deleteRun(id));
      case 'sim':
        await app.simulate(id);
        app.selectRun(id);
      case 'stop-sim':
        await app.stopSimulation();
    }
  }

  /// Members who share (or shared) a position, then the other known members.
  Future<String?> _pickSource(BuildContext context) {
    final s = session;
    final ids = {...s.positions.keys, ...s.members.keys, s.memberId}.toList()
      ..sort((a, b) => (s.positions.containsKey(a) ? 0 : 1).compareTo(s.positions.containsKey(b) ? 0 : 1));
    return showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('Position de ${run.dog}'),
        children: [
          for (final m in ids)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, m),
              child: ListTile(
                leading: Icon(
                  s.members[m]?.bot ?? false ? Icons.smart_toy : Icons.person,
                  color: m == run.source ? Colors.red : null,
                ),
                title: Text(memberName(s, m, app: app)),
                subtitle: Text(
                  s.positions[m] == null ? 'ne partage pas sa position' : 'position ${ago(s.positions[m]!.time)}',
                ),
              ),
            ),
        ],
      ),
    );
  }
}
