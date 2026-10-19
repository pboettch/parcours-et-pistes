import 'package:pep_channel/pep_channel.dart';
import 'package:pep_content/pep_content.dart';

import 'collections.dart';

/// A project as seen by the app: descriptive information (content) plus the
/// owner, track owners and retention settings (channel access list).
class Project {
  Project(this.info, this.acl, {required this.rev, required this.updated});

  final ProjectInfo info;
  final ChannelAcl acl;

  /// Revision and publish time of the project information.
  final int rev;
  final DateTime updated;

  String get name => info.name;
  String? get description => info.description;
  Discipline get discipline => info.discipline;
  String get ownerId => acl.ownerId;

  /// Track id → member assigned to the track; other tracks belong to [ownerId].
  Map<String, String> get trackOwners => acl.assignees[PepCollections.track] ?? const {};

  /// Who may change track [trackId].
  String trackOwner(String trackId) => trackOwners[trackId] ?? ownerId;

  /// How long a shared position stays visible after being published.
  Duration get positionTtl => acl.collections[PepCollections.position]?.ttl ?? PepCollections.defaultPositionTtl;
}
