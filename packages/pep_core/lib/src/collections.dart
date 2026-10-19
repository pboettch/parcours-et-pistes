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

  /// Tracks: one GPX document per item. Each track has one writer, its
  /// owner: the member the project owner assigned it to, else the project
  /// owner.
  static const track = 'track';

  /// Member profiles (`MemberProfile`), item id = member id.
  static const member = 'member';

  /// Live positions (`Position`), item id = member id, expire after the TTL.
  static const position = 'pos';

  static const defaultPositionTtl = Duration(minutes: 30);

  /// Runs (`Run`: a dog on a track, its designated position source), project
  /// owner only.
  static const run = 'run';

  /// The last [rollingPoints] recorded points (`Position`) of a recording
  /// device, on rolling items reused in turn (the times give the order). Item
  /// id = member pseudonym + `.r<slot>[-device]` (hashed).
  static const pathPoint = 'path_pt';

  static const rollingPoints = 20;

  /// The full recorded track of a device (`RecordedPath`), in segments of
  /// [pathSegmentPoints]: the current one is republished as it grows. Item
  /// id = member pseudonym + `.f<segment>[-device]` (hashed, see
  /// `SecureChannel.selfItemId`).
  static const path = 'path';

  static const pathSegmentPoints = 1000;

  /// Collections of a new project.
  static Map<String, CollectionPolicy> defaults({Duration positionTtl = defaultPositionTtl}) => {
    info: const CollectionPolicy(Writers.owner),
    track: const CollectionPolicy(Writers.assigned),
    member: const CollectionPolicy(Writers.self),
    position: CollectionPolicy(Writers.self, ttl: positionTtl),
    run: const CollectionPolicy(Writers.owner),
    pathPoint: const CollectionPolicy(Writers.self),
    path: const CollectionPolicy(Writers.self),
  };
}
