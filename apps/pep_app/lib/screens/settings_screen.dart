import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/app_state.dart';
import '../util.dart';
import 'link_screens.dart';

/// Display name, identity (id, fingerprint, backup to other devices).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.app});

  final AppState app;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final _name = TextEditingController(text: widget.app.displayName);
  final _nameFocus = FocusNode();

  @override
  void dispose() {
    _name.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  AppState get app => widget.app;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) {
      // The name can change elsewhere (e.g. taken from a linked device).
      if (!_nameFocus.hasFocus && _name.text != app.displayName) _name.text = app.displayName;
      return Scaffold(
        appBar: AppBar(title: const Text('Réglages')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextField(
              controller: _name,
              focusNode: _nameFocus,
              decoration: const InputDecoration(
                labelText: 'Mon nom (visible par les participants)',
                helperText: 'Par exemple : « Anne et Rex »',
              ),
              onSubmitted: app.setDisplayName,
              onEditingComplete: () => app.setDisplayName(_name.text),
            ),
            const SizedBox(height: 24),
            Text('Mon identité', style: Theme.of(context).textTheme.titleMedium),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Empreinte'),
              subtitle: Text(app.identity.fingerprint, style: const TextStyle(fontFamily: 'monospace')),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Identifiant'),
              subtitle: SelectableText(app.identity.id, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
              trailing: IconButton(
                icon: const Icon(Icons.copy),
                tooltip: 'Copier',
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: app.identity.id));
                  if (context.mounted) showError(context, 'Identifiant copié');
                },
              ),
            ),
            const SizedBox(height: 8),
            const SizedBox(height: 16),
            Text('Mes appareils', style: Theme.of(context).textTheme.titleMedium),
            const Text(
              'Le même utilisateur sur plusieurs appareils (téléphone, site web…), sans compte ni mot de passe.',
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  icon: const Icon(Icons.add_to_home_screen),
                  label: const Text('Ajouter un appareil'),
                  onPressed: () =>
                      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SendLinkScreen(app: app))),
                ),
                FilledButton.tonalIcon(
                  icon: const Icon(Icons.qr_code_2),
                  label: const Text('Mon identité d\'un autre appareil'),
                  onPressed: () =>
                      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ReceiveLinkScreen(app: app))),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text('Sauvegarde', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.upload),
                  label: const Text('Sauvegarder (texte + phrase secrète)'),
                  onPressed: () => _export(context),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.download),
                  label: const Text('Restaurer une sauvegarde'),
                  onPressed: () => _import(context),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Text(
              'Serveur par défaut des nouveaux projets : $defaultBroker',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Text(
              'Prototype : identité et mots de passe sont conservés sans chiffrement dans ce navigateur.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      );
    },
  );

  Future<String?> _ask(BuildContext context, String title, List<(String, bool)> fields) async {
    final ctrls = [for (final _ in fields) TextEditingController()];
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (i, (label, secret)) in fields.indexed)
              TextField(
                controller: ctrls[i],
                obscureText: secret,
                decoration: InputDecoration(labelText: label),
              ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('OK')),
        ],
      ),
    );
    return ok == true ? ctrls.map((c) => c.text).join('\n') : null;
  }

  Future<void> _export(BuildContext context) async {
    final pass = await _ask(context, 'Phrase secrète de la sauvegarde', [('Phrase secrète', true)]);
    if (pass == null || pass.isEmpty || !context.mounted) return;
    final backup = app.exportIdentity(pass);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sauvegarde de l\'identité'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('À importer sur votre autre appareil, avec la phrase secrète.'),
            const SizedBox(height: 8),
            SelectableText(backup, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Clipboard.setData(ClipboardData(text: backup)),
            child: const Text('Copier'),
          ),
          FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Fermer')),
        ],
      ),
    );
  }

  Future<void> _import(BuildContext context) async {
    final r = await _ask(context, 'Importer une identité', [
      ('Sauvegarde (pepid1.…)', false),
      ('Phrase secrète', true),
    ]);
    if (r == null) return;
    final [backup, pass] = r.split('\n');
    try {
      await app.importIdentity(backup, pass);
      if (context.mounted) showError(context, 'Identité importée');
    } on Exception catch (e) {
      if (context.mounted) showError(context, 'Import impossible : $e');
    }
  }
}
