import 'package:flutter/material.dart';

import '../state/app_state.dart';
import 'members_screen.dart';
import 'projects_screen.dart';
import 'runs_screen.dart';
import 'settings_screen.dart';
import 'tracks_screen.dart';

void openProjects(BuildContext context, AppState app) => _push(context, ProjectsScreen(app: app));

void _push(BuildContext context, Widget screen) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));

class MenuDrawer extends StatelessWidget {
  const MenuDrawer({super.key, required this.app});

  final AppState app;

  @override
  Widget build(BuildContext context) {
    final s = app.session;
    void go(Widget screen) {
      Navigator.of(context).pop(); // the drawer
      _push(context, screen);
    }

    return Drawer(
      child: SafeArea(
        child: ListView(
          children: [
            ListTile(
              title: const Text('Parcours et Pistes', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              subtitle: Text(s?.project.name ?? 'Aucun projet ouvert'),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: const Text('Projets'),
              onTap: () => go(ProjectsScreen(app: app)),
            ),
            ListTile(
              leading: const Icon(Icons.route_outlined),
              title: const Text('Parcours'),
              subtitle: s == null ? null : Text('${s.tracks.length}'),
              enabled: s != null,
              onTap: () => go(TracksScreen(app: app)),
            ),
            ListTile(
              leading: const Icon(Icons.pets),
              title: const Text('Chiens en piste'),
              subtitle: s == null ? null : Text('${s.runs.length}'),
              enabled: s != null,
              onTap: () => go(RunsScreen(app: app)),
            ),
            ListTile(
              leading: const Icon(Icons.group_outlined),
              title: const Text('Participants'),
              subtitle: s == null ? null : Text('${s.members.length}'),
              enabled: s != null,
              onTap: () => go(MembersScreen(app: app)),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.settings_outlined),
              title: const Text('Réglages'),
              onTap: () => go(SettingsScreen(app: app)),
            ),
          ],
        ),
      ),
    );
  }
}
