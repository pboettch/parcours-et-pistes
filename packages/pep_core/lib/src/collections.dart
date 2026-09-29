import 'package:pep_channel/pep_channel.dart';

/// How Parcours et Pistes content maps onto channel collections.
///
/// A new content type = a new collection here (declared in new projects'
/// access lists, or added to existing ones with `SecureChannel.updateAcl`)
/// plus its data type in `pep_content`. Older apps keep enforcing the access
/// rules of collections they do not know and simply ignore their content.
abstract final class PepCollections {
  /// Project information (`ProjectInfo`), one item [infoId], owner only.
  static const info = 'info';
  static const infoId = 'project';

  /// Tracks: one GPX document per item, owner and editors.
  static const track = 'track';

  /// Member profiles (`MemberProfile`), item id = member id.
  static const member = 'member';

  /// Live positions (`Position`), item id = member id, expire after the TTL.
  static const position = 'pos';

  static const defaultPositionTtl = Duration(minutes: 30);

  /// Collections of a new project.
  static Map<String, CollectionPolicy> defaults({Duration positionTtl = defaultPositionTtl}) => {
    info: const CollectionPolicy(Writers.owner),
    track: const CollectionPolicy(Writers.editors),
    member: const CollectionPolicy(Writers.self),
    position: CollectionPolicy(Writers.self, ttl: positionTtl),
  };
}
