import 'dart:typed_data';

import 'geo.dart';
import 'json.dart';

/// A live position (`pos` collection, one item per member). How long it stays
/// visible is decided by the channel (collection TTL), from the publish time.
class Position extends GeoPoint {
  Position({
    required double lat,
    required double lon,
    required this.time,
    this.altitude,
    this.accuracy,
    this.heading,
    this.speed,
  }) : super(lat, lon);

  factory Position.fromJson(Json j) {
    j.checkVersion(version);
    return Position(
      lat: j.reqNum('lat'),
      lon: j.reqNum('lon'),
      time: msToDate(j.req<int>('ts')),
      altitude: j.optNum('alt'),
      accuracy: j.optNum('acc'),
      heading: j.optNum('hdg'),
      speed: j.optNum('spd'),
    );
  }

  factory Position.decode(Uint8List b) => Position.fromJson(decodeJson(b));

  static const version = 1;

  /// When the fix was taken (may be earlier than the publish time).
  final DateTime time;

  /// Metres above sea level.
  final double? altitude;

  /// Horizontal accuracy radius in metres.
  final double? accuracy;

  /// Degrees clockwise from true north.
  final double? heading;

  /// Metres per second.
  final double? speed;

  Json toJson() => {
    'v': version,
    'lat': lat,
    'lon': lon,
    'ts': time.millisecondsSinceEpoch,
    if (altitude != null) 'alt': altitude,
    if (accuracy != null) 'acc': accuracy,
    if (heading != null) 'hdg': heading,
    if (speed != null) 'spd': speed,
  };

  Uint8List encode() => encodeJson(toJson());
}
