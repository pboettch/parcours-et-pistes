import 'package:flutter/material.dart';
import 'package:pep_core/pep_core.dart';

import '../state/app_state.dart';
import '../util.dart';

/// Members who made themselves known (profile) or share a position.
class MembersScreen extends StatelessWidget {
  const MembersScreen({super.key, required this.app});

  final AppState app;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) {
      final s = app.session;
      if (s == null) return const Scaffold();
      final ids = {s.memberId, s.ownerId, ...s.members.keys, ...s.positions.keys}.toList()
        ..sort((a, b) => memberName(s, a).toLowerCase().compareTo(memberName(s, b).toLowerCase()));
      final editors = s.project.editors;
      return Scaffold(
        appBar: AppBar(title: const Text('Participants')),
        body: ListView(
          children: [
            for (final id in ids)
              ListTile(
                leading: CircleAvatar(
                  child: s.members[id]?.bot ?? false
                      ? const Icon(Icons.smart_toy)
                      : Text(memberName(s, id)[0].toUpperCase()),
                ),
                title: Text(memberName(s, id, app: app)),
                subtitle: Text(
                  [
                    if (id == s.ownerId) 'responsable' else if (editors.contains(id)) 'éditeur',
                    if (s.members[id]?.bot ?? false) 'automatique',
                    s.positions[id] == null ? 'position non partagée' : 'position ${ago(s.positions[id]!.time)}',
                    'empreinte ${fingerprintOf(id)}',
                  ].join(' · '),
                ),
                trailing: s.isOwner && id != s.memberId
                    ? Switch(
                        value: editors.contains(id),
                        onChanged: (v) => app.act((s) => v ? s.addEditor(id) : s.removeEditor(id)),
                      )
                    : null,
              ),
            if (s.isOwner)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Interrupteur : éditeur (peut publier des parcours et gérer les passages).'),
              ),
          ],
        ),
      );
    },
  );
}
