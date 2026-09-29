/// Parcours et Pistes project sessions: the content model (`pep_content`)
/// mapped onto the secure channel (`pep_channel`). The one import apps need.
library;

import 'package:pep_channel/pep_channel.dart' show ChannelNotFoundException;

export 'package:pep_channel/pep_channel.dart'
    hide ChannelEvent, AclUpdated, ItemUpdated, ItemRemoved, PasswordChanged, ChannelDeleted, MessageRejected;
export 'package:pep_content/pep_content.dart' hide utf8Bytes;

export 'src/collections.dart';
export 'src/project.dart';
export 'src/project_session.dart';
export 'src/session_events.dart';
export 'src/track.dart';

/// Alias used by the apps: a project is a channel.
typedef ProjectNotFoundException = ChannelNotFoundException;
