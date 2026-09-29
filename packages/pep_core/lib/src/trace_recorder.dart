import 'dart:async';
import 'dart:convert';

import 'package:pep_channel/pep_channel.dart';
import 'package:pep_content/pep_content.dart' hide utf8Bytes;

import 'collections.dart';

/// Records this device's positions into the `trace` collection: one GPX track
/// segment per hour, republished at most every [flushInterval].
class TraceRecorder {
  TraceRecorder(this.channel, {required this.deviceId, required this.flushInterval});

  final SecureChannel channel;
  final String? deviceId;
  final Duration flushInterval;

  int? _slot;
  var _points = <GpxPoint>[];
  var _dirty = false;
  DateTime? _lastFlush;
  Timer? _timer;

  /// Item id of this device's segment for hour [slot] (hours since the epoch).
  String itemId(int slot) {
    var suffix = 'h$slot${deviceId == null ? '' : '-$deviceId'}';
    if (suffix.length > 32) suffix = suffix.substring(0, 32);
    return channel.selfItemId(device: suffix);
  }

  Future<void> add(Position p) async {
    final slot = p.time.millisecondsSinceEpoch ~/ Duration.millisecondsPerHour;
    if (slot != _slot) {
      await flush();
      _slot = slot;
      _points = _existing(slot); // continue a segment of an earlier session
    }
    _points.add(GpxPoint(p.lat, p.lon, ele: p.altitude, time: p.time));
    _dirty = true;
    final since = _lastFlush == null ? null : DateTime.now().difference(_lastFlush!);
    if (since == null || since >= flushInterval) {
      await flush();
    } else {
      _timer ??= Timer(flushInterval - since, () => unawaited(flush().catchError((Object _) {})));
    }
  }

  /// Publishes the pending points.
  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    if (!_dirty) return;
    _dirty = false;
    _lastFlush = DateTime.now();
    final gpx = Gpx(
      tracks: [
        GpxTrack(segments: [List.of(_points)]),
      ],
    );
    await channel.put(PepCollections.trace, itemId(_slot!), utf8.encode(gpx.toXml(pretty: false)));
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
  }

  List<GpxPoint> _existing(int slot) {
    final item = channel.item(PepCollections.trace, itemId(slot));
    if (item == null) return [];
    try {
      return Gpx.parse(utf8.decode(item.body)).tracks.expand((t) => t.points).toList();
    } on Exception {
      return [];
    }
  }
}
