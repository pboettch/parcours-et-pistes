import '../crypto/identity.dart';
import '../errors.dart';
import 'ids.dart';
import 'topics.dart';

/// Invitation to a project. The password is NOT part of the link and must be
/// shared through another channel.
///
/// Everything lives in the URL fragment, which browsers never send to servers:
/// `<prefix>#p=<uuid>&o=<owner id>[&b=<broker url>][&t=<topic base>]`
class JoinLink {
  JoinLink({
    required String projectId,
    required this.ownerId,
    this.broker,
    this.topicBase = ProjectTopics.defaultBase,
  }) : projectId = checkProjectId(projectId) {
    publicKeyFromId(ownerId); // validates
    ProjectTopics(projectId, base: topicBase); // validates base
    if (broker != null) _checkBroker(broker!);
  }

  factory JoinLink.parse(String link) {
    final Uri uri;
    try {
      uri = Uri.parse(link.trim());
    } on FormatException {
      throw const FormatPepException('invalid join link');
    }
    final Map<String, String> q;
    try {
      q = Uri.splitQueryString(uri.fragment);
    } catch (_) {
      throw const FormatPepException('invalid join link');
    }
    final p = q['p'], o = q['o'];
    if (p == null || o == null) throw const FormatPepException('join link lacks project or owner');
    return JoinLink(projectId: p, ownerId: o, broker: q['b'], topicBase: q['t'] ?? ProjectTopics.defaultBase);
  }

  /// Default link prefix (app deep link). Apps may use a web URL instead.
  static const defaultPrefix = 'parcoursetpistes://join';

  final String projectId;

  /// Member id (public key) of the project owner: the trust anchor used to
  /// verify the project document.
  final String ownerId;

  /// Broker URL (`mqtt://`, `mqtts://`, `ws://`, `wss://`), null = app default.
  final String? broker;

  final String topicBase;

  String toUri({String prefix = defaultPrefix}) {
    final q = {
      'p': projectId,
      'o': ownerId,
      'b': ?broker,
      if (topicBase != ProjectTopics.defaultBase) 't': topicBase,
    };
    final frag = q.entries.map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}').join('&');
    return '$prefix#$frag';
  }

  @override
  String toString() => toUri();

  static void _checkBroker(String b) {
    final u = Uri.tryParse(b);
    if (u == null || !const {'mqtt', 'mqtts', 'ws', 'wss'}.contains(u.scheme) || u.host.isEmpty) {
      throw FormatPepException('invalid broker url "$b"');
    }
  }
}
