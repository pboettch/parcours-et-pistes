import 'dart:convert';

import 'package:pep_channel/pep_channel.dart';
import 'package:pep_content/pep_content.dart';

/// A track: a GPX document (name, trail, RU objects as waypoints, custom `pep`
/// sections) plus the channel metadata of its current revision.
class Track {
  Track(ChannelItem item, {Gpx? parsed})
    : id = item.id,
      rev = item.rev,
      updated = item.time,
      signerId = item.signerId,
      visibleTo = item.recipients,
      gpx = utf8.decode(item.body),
      _parsed = parsed;

  final Gpx? _parsed;

  final String id;
  final int rev;

  /// Publish time of this revision.
  final DateTime updated;

  /// Member (owner or editor) who published this revision.
  final String signerId;

  /// Members allowed to see this track (always including the owner and the
  /// publisher); null = every member.
  final Set<String>? visibleTo;

  /// The GPX 1.1 document as published.
  final String gpx;

  /// The parsed [gpx].
  late final Gpx document = _parsed ?? Gpx.parse(gpx);

  /// Display name: GPX metadata name, else the first track's name.
  String? get name => document.name ?? document.tracks.firstOrNull?.name;
}
