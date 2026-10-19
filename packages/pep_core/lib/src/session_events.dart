import 'package:pep_content/pep_content.dart';

import 'project.dart';
import 'track.dart';

/// Changes observed by a `ProjectSession`.
sealed class SessionEvent {
  const SessionEvent();
}

/// Project information, track owners or settings changed.
class ProjectUpdated extends SessionEvent {
  const ProjectUpdated(this.project);

  final Project project;
}

class TrackUpdated extends SessionEvent {
  const TrackUpdated(this.track);

  final Track track;
}

class TrackRemoved extends SessionEvent {
  const TrackRemoved(this.trackId);

  final String trackId;
}

class MemberUpdated extends SessionEvent {
  const MemberUpdated(this.memberId, this.profile);

  final String memberId;
  final MemberProfile profile;
}

class MemberRemoved extends SessionEvent {
  const MemberRemoved(this.memberId);

  final String memberId;
}

class PositionUpdated extends SessionEvent {
  const PositionUpdated(this.memberId, this.position);

  final String memberId;
  final Position position;
}

/// A position was cleared by its member or expired.
class PositionRemoved extends SessionEvent {
  const PositionRemoved(this.memberId);

  final String memberId;
}

class RunUpdated extends SessionEvent {
  const RunUpdated(this.runId, this.run);

  final String runId;
  final Run run;
}

class RunRemoved extends SessionEvent {
  const RunRemoved(this.runId);

  final String runId;
}

/// The recorded path of member [memberId] changed (see `ProjectSession.path`).
class PathUpdated extends SessionEvent {
  const PathUpdated(this.memberId);

  final String memberId;
}

/// The project was deleted by its owner.
class ProjectDeleted extends SessionEvent {
  const ProjectDeleted();
}

/// A message was ignored: not decryptable, not verifiable, not authorized
/// (`PepException`) or with invalid content (`ContentFormatException`).
class MessageRejected extends SessionEvent {
  const MessageRejected(this.topic, this.error);

  final String topic;
  final Exception error;

  @override
  String toString() => 'MessageRejected($topic, $error)';
}
