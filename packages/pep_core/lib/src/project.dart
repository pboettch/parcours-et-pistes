import 'package:pep_channel/pep_channel.dart';
import 'package:pep_content/pep_content.dart';

import 'collections.dart';

/// A project as seen by the app: descriptive information (content) plus the
/// owner, editors and retention settings (channel access list).
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
  Set<String> get editors => acl.editors;

  /// How long a shared position stays visible after being published.
  Duration get positionTtl => acl.collections[PepCollections.position]?.ttl ?? PepCollections.defaultPositionTtl;

  bool canEditTracks(String memberId) => acl.canWrite(memberId, PepCollections.track, '-');
}
