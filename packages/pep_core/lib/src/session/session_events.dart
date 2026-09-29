import '../errors.dart';
import '../model/member.dart';
import '../model/position.dart';
import '../model/project_doc.dart';
import '../model/track_doc.dart';

/// Changes observed by a `ProjectSession`.
sealed class SessionEvent {
  const SessionEvent();
}

class ProjectUpdated extends SessionEvent {
  const ProjectUpdated(this.project);

  final ProjectDoc project;
}

class TrackUpdated extends SessionEvent {
  const TrackUpdated(this.track, {required this.signerId});

  final TrackDoc track;

  /// Member who published this revision (owner or editor).
  final String signerId;
}

class TrackRemoved extends SessionEvent {
  const TrackRemoved(this.trackId);

  final String trackId;
}

class MemberUpdated extends SessionEvent {
  const MemberUpdated(this.memberId, this.member);

  final String memberId;
  final MemberDoc member;
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

/// The owner changed the project password. The session is locked until
/// `ProjectSession.unlock` is called with the new password.
class PasswordChanged extends SessionEvent {
  const PasswordChanged();
}

/// The project was deleted by its owner (meta and project doc cleared).
class ProjectDeleted extends SessionEvent {
  const ProjectDeleted();
}

/// A message could not be decrypted, verified or authorized and was ignored.
class MessageRejected extends SessionEvent {
  const MessageRejected(this.topic, this.error);

  final String topic;
  final PepException error;

  @override
  String toString() => 'MessageRejected($topic, $error)';
}
