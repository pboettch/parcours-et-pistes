import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pep_core/pep_core.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../state/app_state.dart';
import '../state/storage.dart';
import '../util.dart';

/// New device: shows a link (QR code) for the user's other device, waits for
/// the identity it sends, and becomes the same user.
class ReceiveLinkScreen extends StatefulWidget {
  const ReceiveLinkScreen({super.key, required this.app});

  final AppState app;

  @override
  State<ReceiveLinkScreen> createState() => _ReceiveLinkScreenState();
}

class _ReceiveLinkScreenState extends State<ReceiveLinkScreen> {
  late final LinkRequest _request = widget.app.createLinkRequest();
  String? _status;
  var _done = false;

  @override
  void initState() {
    super.initState();
    unawaited(_wait());
  }

  @override
  void dispose() {
    _request.dispose();
    super.dispose();
  }

  Future<void> _wait() async {
    final LinkTransfer t;
    try {
      t = await widget.app.waitForLink(_request);
    } on TimeoutException {
      if (mounted) setState(() => _status = 'Délai dépassé : recommencez.');
      return;
    } on Exception catch (e) {
      if (mounted) setState(() => _status = 'Échec : $e');
      return;
    }
    if (!mounted) return;
    ({Identity identity, String? name, List<SavedProject> projects})? link;
    String? password;
    while (link == null) {
      try {
        link = widget.app.readLink(t, password: password);
      } on WrongPasswordException {
        if (password != null && mounted) showError(context, 'Mot de passe incorrect');
        password = await _askPassword();
        if (password == null) {
          if (mounted) setState(() => _status = 'Annulé.');
          return;
        }
      }
    }
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Utiliser cette identité ?'),
        content: Text(
          'Empreinte ${link!.identity.fingerprint}'
          '${link.name == null ? '' : ' (${link.name})'}\n'
          '${link.projects.length} projet(s) transmis.\n\n'
          'L\'identité actuelle de cet appareil sera remplacée.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Utiliser')),
        ],
      ),
    );
    if (ok != true) {
      if (mounted) setState(() => _status = 'Annulé.');
      return;
    }
    await widget.app.applyLink(link);
    if (mounted) {
      setState(() => _done = true);
      showError(context, 'Cet appareil utilise maintenant votre identité.');
      Navigator.of(context).pop();
    }
  }

  Future<String?> _askPassword() {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Mot de passe'),
        content: TextField(
          controller: c,
          obscureText: true,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Mot de passe choisi sur l\'autre appareil'),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(context, c.text), child: const Text('OK')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Mon identité d\'un autre appareil')),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Text(
          'Sur votre autre appareil (téléphone…), ouvrez Réglages → « Ajouter un appareil », '
          'puis scannez ce code ou collez le lien.',
        ),
        const SizedBox(height: 16),
        Center(
          child: Container(
            color: Colors.white,
            padding: const EdgeInsets.all(12),
            child: QrImageView(data: _request.uri, size: 240),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: SelectableText(_request.uri, style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
            ),
            IconButton(
              tooltip: 'Copier le lien',
              icon: const Icon(Icons.copy),
              onPressed: () => Clipboard.setData(ClipboardData(text: _request.uri)),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text('Code de vérification', style: Theme.of(context).textTheme.labelLarge),
        Text(_request.code, style: Theme.of(context).textTheme.displaySmall),
        const Text('L\'autre appareil doit afficher le même code.'),
        const SizedBox(height: 24),
        if (_status != null)
          Text(_status!)
        else if (!_done)
          const Row(
            children: [
              SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 12),
              Text('En attente de l\'autre appareil…'),
            ],
          ),
      ],
    ),
  );
}

/// Existing device: sends this identity (and the projects) to a new device.
class SendLinkScreen extends StatefulWidget {
  const SendLinkScreen({super.key, required this.app});

  final AppState app;

  @override
  State<SendLinkScreen> createState() => _SendLinkScreenState();
}

class _SendLinkScreenState extends State<SendLinkScreen> {
  final _link = TextEditingController();
  final _password = TextEditingController();
  var _withProjects = true;
  var _sending = false;
  LinkRequest? _request;

  void _parse(String text) {
    LinkRequest? r;
    try {
      r = text.trim().isEmpty ? null : LinkRequest.parse(text);
    } on PepException {
      r = null;
    }
    setState(() => _request = r);
  }

  Future<void> _send() async {
    setState(() => _sending = true);
    try {
      await widget.app.sendLink(
        _link.text,
        password: _password.text.isEmpty ? null : _password.text,
        withProjects: _withProjects,
      );
      if (mounted) {
        showError(context, 'Identité envoyée.');
        Navigator.of(context).pop();
      }
    } on Exception catch (e) {
      if (mounted) showError(context, 'Échec de l\'envoi : $e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Ajouter un appareil')),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Text(
          'Sur le nouvel appareil, ouvrez Réglages → « Mon identité d\'un autre appareil », '
          'puis collez ici le lien affiché (scan du QR code : à venir sur téléphone).',
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _link,
          minLines: 1,
          maxLines: 3,
          decoration: const InputDecoration(labelText: 'Lien du nouvel appareil'),
          onChanged: _parse,
        ),
        if (_request != null) ...[
          const SizedBox(height: 20),
          Text('Code de vérification', style: Theme.of(context).textTheme.labelLarge),
          Text(_request!.code, style: Theme.of(context).textTheme.displaySmall),
          const Text('Envoyez seulement si le nouvel appareil affiche le même code.'),
          const SizedBox(height: 20),
          TextField(
            controller: _password,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Mot de passe (facultatif)',
              helperText: 'Second facteur : à taper sur le nouvel appareil',
            ),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _withProjects,
            onChanged: (v) => setState(() => _withProjects = v),
            title: const Text('Transmettre mes projets'),
            subtitle: Text('${widget.app.projects.length} projet(s), avec leurs mots de passe'),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            icon: _sending
                ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.send),
            label: const Text('Envoyer mon identité'),
            onPressed: _sending ? null : _send,
          ),
        ] else if (_link.text.trim().isNotEmpty)
          const Padding(padding: EdgeInsets.only(top: 8), child: Text('Ce n\'est pas un lien d\'appareil.')),
      ],
    ),
  );
}
