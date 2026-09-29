import 'dart:convert';
import 'dart:math';

import 'package:pep_core/pep_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A project this device has joined: enough to open it again.
class SavedProject {
  SavedProject({required this.link, required this.password, required this.name});

  factory SavedProject.fromJson(Map<String, dynamic> j) =>
      SavedProject(link: j['link'] as String, password: j['password'] as String, name: j['name'] as String);

  final String link;
  final String password;
  String name;

  String get projectId => JoinLink.parse(link).channelId;

  Map<String, dynamic> toJson() => {'link': link, 'password': password, 'name': name};
}

/// Device-local persistence.
///
/// PoC: kept in shared_preferences (localStorage on the web), unencrypted.
/// TODO(app): platform secure storage for the identity seed and passwords.
class Storage {
  Storage(this._p);

  static Future<Storage> open() async => Storage(await SharedPreferences.getInstance());

  final SharedPreferences _p;

  Identity identity(PepCrypto c) {
    final seed = _p.getString('identity');
    if (seed != null) return Identity.fromSeed(c, unb64u(seed));
    final id = Identity.generate(c);
    saveIdentity(id);
    return id;
  }

  void saveIdentity(Identity id) => _p.setString('identity', b64u(id.exportSeed()));

  /// A stable id for this installation (positions and paths of several
  /// devices of one member stay apart).
  String get deviceId {
    var d = _p.getString('device');
    if (d == null) {
      final r = Random.secure();
      d = 'd${List.generate(8, (_) => r.nextInt(36).toRadixString(36)).join()}';
      _p.setString('device', d);
    }
    return d;
  }

  String? get displayName => _p.getString('name');
  set displayName(String? v) => v == null ? _p.remove('name') : _p.setString('name', v);

  String? get layer => _p.getString('layer');
  set layer(String? v) => v == null ? _p.remove('layer') : _p.setString('layer', v);

  String? get lastProject => _p.getString('lastProject');
  set lastProject(String? v) => v == null ? _p.remove('lastProject') : _p.setString('lastProject', v);

  List<SavedProject> get projects => [
    for (final j in jsonDecode(_p.getString('projects') ?? '[]') as List<dynamic>)
      SavedProject.fromJson(j as Map<String, dynamic>),
  ];

  set projects(List<SavedProject> v) => _p.setString('projects', jsonEncode([for (final p in v) p.toJson()]));

  /// Identity of the simulated dog (a bot member), kept so that it stays the
  /// same member across simulations.
  Identity simulatorIdentity(PepCrypto c) {
    final seed = _p.getString('simIdentity');
    if (seed != null) return Identity.fromSeed(c, unb64u(seed));
    final id = Identity.generate(c);
    _p.setString('simIdentity', b64u(id.exportSeed()));
    return id;
  }
}
