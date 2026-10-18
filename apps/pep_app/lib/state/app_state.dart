import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:pep_core/pep_core.dart';

import '../map/base_layers.dart';
import 'dog_simulator.dart';
import 'storage.dart';

/// Broker for new projects (joined projects use the broker of their link).
const defaultBroker = String.fromEnvironment('PEP_BROKER', defaultValue: 'ws://127.0.0.1:18080');

/// State of the app: identity, known projects, the open project session, own
/// position, and what the map shows.
class AppState extends ChangeNotifier {
  AppState._(this.crypto, this.storage) : identity = storage.identity(crypto) {
    layer = BaseLayer.byId(storage.layer);
  }

  static Future<AppState> load() async {
    final s = AppState._(await PepCrypto.init(), await Storage.open());
    unawaited(s._reopenLast());
    return s;
  }

  final PepCrypto crypto;
  final Storage storage;
  Identity identity;

  // ------------------------------------------------------------- project

  List<SavedProject> get projects => storage.projects;
  ProjectSession? session;
  SavedProject? current;

  /// Opening a project is in progress.
  bool busy = false;

  /// Last error to show (cleared when shown).
  String? error;

  StreamSubscription<SessionEvent>? _sessionSub;
  DogSimulator? simulator;

  String get displayName => storage.displayName ?? '';

  Future<void> _reopenLast() async {
    final id = storage.lastProject;
    final p = projects.where((p) => p.projectId == id).firstOrNull;
    if (p != null) await open(p);
  }

  /// Joins a project from its [link] and [password] and opens it.
  Future<void> join(String link, String password) async {
    final l = JoinLink.parse(link.trim());
    final existing = projects.where((p) => p.projectId == l.channelId).firstOrNull;
    await open(SavedProject(link: l.toUri().toString(), password: password, name: existing?.name ?? '…'));
  }

  /// Creates a new project owned by this device's identity and opens it.
  Future<void> create({
    required String name,
    required Discipline discipline,
    required String password,
    String broker = defaultBroker,
  }) async {
    await _run(() async {
      await _closeSession();
      final s = await ProjectSession.create(
        crypto: crypto,
        transport: _transport(broker),
        identity: identity,
        name: name,
        discipline: discipline,
        password: password,
        linkBroker: broker,
        deviceId: storage.deviceId,
      );
      _attach(s, SavedProject(link: s.joinLink.toUri().toString(), password: password, name: name));
    });
  }

  Future<void> open(SavedProject p) async {
    await _run(() async {
      await _closeSession();
      final link = JoinLink.parse(p.link);
      final s = await ProjectSession.join(
        crypto: crypto,
        transport: _transport(link.broker ?? defaultBroker),
        identity: identity,
        link: link,
        password: p.password,
        deviceId: storage.deviceId,
      );
      _attach(s, p);
    });
  }

  Future<void> closeProject() async {
    await _closeSession();
    storage.lastProject = null;
    notifyListeners();
  }

  void forget(SavedProject p) {
    storage.projects = [...projects.where((x) => x.projectId != p.projectId)];
    if (storage.lastProject == p.projectId) storage.lastProject = null;
    notifyListeners();
  }

  Future<void> unlock(String password) async {
    final s = session, p = current;
    if (s == null || p == null) return;
    await _run(() async {
      await s.unlock(password);
      _save(SavedProject(link: p.link, password: password, name: p.name));
      await _publishProfile();
    });
  }

  void _attach(ProjectSession s, SavedProject p) {
    session = s;
    p.name = s.project.name;
    current = p;
    _save(p);
    storage.lastProject = p.projectId;
    selectedTrackId = null;
    selectedRunId = s.runs.entries.where((r) => r.value.status == RunStatus.running).firstOrNull?.key;
    _wasSource = false;
    _sessionSub = s.events.listen(_onSessionEvent);
    _checkSource();
    unawaited(_publishProfile());
    if (sharing && myPosition != null) unawaited(_publishMine(myPosition!));
  }

  void _save(SavedProject p) {
    storage.projects = [p, ...projects.where((x) => x.projectId != p.projectId)];
  }

  /// Whether this member was a run's designated position source at the last event.
  var _wasSource = false;

  void _onSessionEvent(SessionEvent e) {
    _checkSource();
    switch (e) {
      case ProjectUpdated(:final project):
        if (current case final p? when p.name != project.name) {
          p.name = project.name;
          _save(p);
        }
      case TrackRemoved(:final trackId) when trackId == selectedTrackId:
        selectedTrackId = null;
      case RunRemoved(:final runId) when runId == selectedRunId:
        selectedRunId = null;
      case PasswordChanged():
        error = 'Le mot de passe du projet a changé.';
      case ProjectDeleted():
        error = 'Le projet a été supprimé.';
        forget(current!);
        unawaited(_closeSession());
      default:
    }
    notifyListeners();
  }

  /// Tells the member when the leader makes them (or stops making them) the
  /// position of a dog.
  void _checkSource() {
    final s = session;
    if (s == null) return;
    final source = s.recordingPath && s.pathMode == PathMode.whenSource;
    if (source == _wasSource) return;
    _wasSource = source;
    if (source) {
      final dogs = [
        for (final r in s.runs.values)
          if (r.status != RunStatus.finished && r.source == s.memberId) r.dog,
      ];
      error =
          'Votre position est celle du chien ${dogs.join(', ')} : elle est enregistrée.'
          '${sharing ? '' : ' Activez le partage de votre position.'}';
    } else {
      error = 'Votre position n\'est plus celle d\'un chien.';
    }
  }

  Future<void> _closeSession() async {
    await simulator?.stop();
    simulator = null;
    await _sessionSub?.cancel();
    _sessionSub = null;
    final s = session;
    session = null;
    current = null;
    if (s != null) {
      try {
        await s.close();
      } on Exception {
        // closing anyway
      }
    }
  }

  Future<void> _run(Future<void> Function() f) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      await f();
    } on WrongPasswordException {
      error = 'Mot de passe incorrect.';
    } on ChannelNotFoundException {
      error = 'Projet introuvable sur le serveur.';
    } on TransportException catch (e) {
      error = 'Connexion au serveur impossible (${e.message}).';
    } on PepException catch (e) {
      error = e.message;
    } on FormatException catch (e) {
      error = 'Lien invalide (${e.message}).';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Transport _transport(String broker) => Mqtt5Transport(BrokerConfig(Uri.parse(broker)));

  // ------------------------------------------------------------ identity

  Future<void> setDisplayName(String name) async {
    storage.displayName = name.trim().isEmpty ? null : name.trim();
    notifyListeners();
    await _publishProfile();
  }

  Future<void> _publishProfile() async {
    final s = session;
    if (s == null || s.locked || displayName.isEmpty) return;
    try {
      await s.setMemberName(displayName);
    } on Exception {
      // shown as missing name; retried on the next change
    }
  }

  String exportIdentity(String passphrase) => IdentityBackup.export(crypto, identity, passphrase);

  /// Replaces this device's identity with the one of a backup (the same
  /// person on another device). Reopens the current project under it.
  Future<void> importIdentity(String backup, String passphrase) async {
    final id = IdentityBackup.import(crypto, backup.trim(), passphrase);
    identity = id;
    storage.saveIdentity(id);
    final p = current;
    if (p != null) {
      await open(p);
    } else {
      notifyListeners();
    }
  }

  // ---------------------------------------------------------- my position

  Position? myPosition;
  String? locationError;
  bool sharing = false;
  StreamSubscription<geo.Position>? _geoSub;
  DateTime? _lastPublished;

  /// Minimum time between two published positions.
  static const publishInterval = Duration(seconds: 5);

  Future<void> startLocating() async {
    if (_geoSub != null) return;
    try {
      var perm = await geo.Geolocator.checkPermission();
      if (perm == geo.LocationPermission.denied) perm = await geo.Geolocator.requestPermission();
      if (perm == geo.LocationPermission.denied || perm == geo.LocationPermission.deniedForever) {
        locationError = 'Localisation refusée';
        notifyListeners();
        return;
      }
      _geoSub = geo.Geolocator.getPositionStream(
        locationSettings: const geo.LocationSettings(accuracy: geo.LocationAccuracy.best),
      ).listen(_onFix, onError: (Object e) => _locationFailed('$e'));
    } on Exception catch (e) {
      _locationFailed('$e');
    }
  }

  void _locationFailed(String e) {
    locationError = 'Localisation indisponible';
    debugPrint('location: $e');
    _geoSub?.cancel();
    _geoSub = null;
    notifyListeners();
  }

  void _onFix(geo.Position f) {
    locationError = null;
    myPosition = Position(
      lat: f.latitude,
      lon: f.longitude,
      time: f.timestamp.toUtc(),
      accuracy: f.accuracy,
      altitude: f.altitude == 0 ? null : f.altitude,
      heading: f.heading.isNaN || f.heading < 0 ? null : f.heading,
      speed: f.speed.isNaN || f.speed < 0 ? null : f.speed,
    );
    if (sharing) unawaited(_publishMine(myPosition!));
    notifyListeners();
  }

  Future<void> setSharing(bool on) async {
    sharing = on;
    notifyListeners();
    final s = session;
    if (s == null || s.locked) return;
    if (on) {
      await startLocating();
      if (myPosition != null) await _publishMine(myPosition!, force: true);
    } else {
      await s.clearPosition();
    }
  }

  Future<void> _publishMine(Position p, {bool force = false}) async {
    final s = session;
    if (s == null || s.locked) return;
    final now = DateTime.now();
    if (!force && _lastPublished != null && now.difference(_lastPublished!) < publishInterval) return;
    _lastPublished = now;
    try {
      await s.publishPosition(p);
    } on Exception catch (e) {
      debugPrint('publish position: $e');
    }
  }

  // ------------------------------------------------------------- the map

  late BaseLayer layer;
  String? selectedTrackId;
  String? selectedRunId;
  bool showCorridors = false;
  bool showDistance = true;

  void setLayer(BaseLayer l) {
    layer = l;
    storage.layer = l.id;
    notifyListeners();
  }

  void selectTrack(String? id) {
    selectedTrackId = id;
    notifyListeners();
  }

  void selectRun(String? id) {
    selectedRunId = id;
    if (id != null) selectedTrackId = session?.runs[id]?.track ?? selectedTrackId;
    notifyListeners();
  }

  void toggleCorridors() {
    showCorridors = !showCorridors;
    notifyListeners();
  }

  void toggleDistance() {
    showDistance = !showDistance;
    notifyListeners();
  }

  // ----------------------------------------------------------- simulation

  /// Starts a simulated dog walking the track of run [runId] (development).
  Future<void> simulate(String runId, {double rate = 5}) async {
    await simulator?.stop();
    simulator = await DogSimulator.start(this, runId, rate: rate);
    notifyListeners();
  }

  Future<void> stopSimulation() async {
    await simulator?.stop();
    simulator = null;
    notifyListeners();
  }

  /// Runs [f] against the open session, reporting failures as [error].
  Future<void> act(Future<void> Function(ProjectSession s) f) async {
    final s = session;
    if (s == null) return;
    try {
      await f(s);
    } on PepException catch (e) {
      error = e.message;
    } on ArgumentError catch (e) {
      error = '${e.message}';
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _geoSub?.cancel();
    unawaited(_closeSession());
    super.dispose();
  }
}
