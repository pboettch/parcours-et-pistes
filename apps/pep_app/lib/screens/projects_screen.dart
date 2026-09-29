import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pep_core/pep_core.dart';

import '../state/app_state.dart';
import '../util.dart';

/// Known projects; join one from a link, or create one.
class ProjectsScreen extends StatelessWidget {
  const ProjectsScreen({super.key, required this.app});

  final AppState app;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) {
      final s = app.session;
      return Scaffold(
        appBar: AppBar(title: const Text('Projets')),
        body: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            if (s != null && app.current != null) _CurrentProject(app: app, session: s),
            for (final p in app.projects)
              ListTile(
                leading: Icon(p.projectId == s?.projectId ? Icons.folder_open : Icons.folder_outlined),
                title: Text(p.name),
                subtitle: Text(p.projectId.substring(0, 8)),
                selected: p.projectId == s?.projectId,
                onTap: app.busy
                    ? null
                    : () async {
                        await app.open(p);
                        if (context.mounted && app.session != null) Navigator.of(context).pop();
                      },
                trailing: PopupMenuButton<String>(
                  onSelected: (_) => app.forget(p),
                  itemBuilder: (_) => const [PopupMenuItem(value: 'forget', child: Text('Oublier sur cet appareil'))],
                ),
              ),
            if (app.projects.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('Aucun projet. Rejoignez un projet avec son lien et son mot de passe, ou créez-en un.'),
              ),
          ],
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    icon: const Icon(Icons.login),
                    label: const Text('Rejoindre'),
                    onPressed: app.busy ? null : () => _join(context),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.add),
                    label: const Text('Créer'),
                    onPressed: app.busy ? null : () => _create(context),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );

  Future<void> _join(BuildContext context) async {
    final link = TextEditingController(), password = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rejoindre un projet'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: link,
              decoration: const InputDecoration(labelText: 'Lien d\'invitation'),
              maxLines: 3,
              minLines: 1,
            ),
            TextField(
              controller: password,
              decoration: const InputDecoration(labelText: 'Mot de passe du projet'),
              obscureText: true,
              onSubmitted: (_) => Navigator.pop(context, true),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Rejoindre')),
        ],
      ),
    );
    if (ok != true) return;
    await app.join(link.text, password.text);
    if (context.mounted && app.session != null) Navigator.of(context).pop();
  }

  Future<void> _create(BuildContext context) async {
    final name = TextEditingController(), password = TextEditingController();
    var discipline = Discipline.ru;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Nouveau projet'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                decoration: const InputDecoration(labelText: 'Nom'),
              ),
              const SizedBox(height: 12),
              SegmentedButton<Discipline>(
                segments: const [
                  ButtonSegment(value: Discipline.ru, label: Text('Recherche utilitaire')),
                  ButtonSegment(value: Discipline.mt, label: Text('Man trailing')),
                ],
                selected: {discipline},
                onSelectionChanged: (v) => setState(() => discipline = v.single),
              ),
              TextField(
                controller: password,
                decoration: const InputDecoration(labelText: 'Mot de passe du projet'),
                obscureText: true,
              ),
              const SizedBox(height: 8),
              Text('Serveur : $defaultBroker', style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Créer')),
          ],
        ),
      ),
    );
    if (ok != true || name.text.trim().isEmpty || password.text.isEmpty) return;
    await app.create(name: name.text.trim(), discipline: discipline, password: password.text);
  }
}

class _CurrentProject extends StatelessWidget {
  const _CurrentProject({required this.app, required this.session});

  final AppState app;
  final ProjectSession session;

  @override
  Widget build(BuildContext context) {
    final p = session.project;
    final role = session.isOwner ? 'responsable' : (session.canEditTracks ? 'éditeur' : 'participant');
    final link = session.joinLink.toUri().toString();
    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(p.name, style: Theme.of(context).textTheme.titleLarge),
            if (p.description != null) Text(p.description!),
            const SizedBox(height: 4),
            Text(
              '${p.discipline == Discipline.ru ? 'Recherche utilitaire' : 'Man trailing'} · '
              '${session.tracks.length} parcours · vous êtes $role',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (session.locked)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: FilledButton.tonalIcon(
                  icon: const Icon(Icons.lock_open),
                  label: const Text('Nouveau mot de passe…'),
                  onPressed: () => _unlock(context),
                ),
              ),
            const SizedBox(height: 12),
            Text(
              'Inviter : envoyez ce lien, et le mot de passe séparément.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: SelectableText(
                    link,
                    maxLines: 2,
                    style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                  ),
                ),
                IconButton(
                  tooltip: 'Copier le lien',
                  icon: const Icon(Icons.copy),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: link));
                    if (context.mounted) showError(context, 'Lien copié');
                  },
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: app.closeProject, child: const Text('Fermer le projet')),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _unlock(BuildContext context) async {
    final pw = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Le mot de passe a changé'),
        content: TextField(
          controller: pw,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'Nouveau mot de passe'),
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Déverrouiller'))],
      ),
    );
    if (ok == true) await app.unlock(pw.text);
  }
}
