import 'dart:async';
import 'dart:typed_data';

enum TransportState { disconnected, connecting, connected }

class TransportMessage {
  TransportMessage(this.topic, this.payload, {this.retained = false});

  final String topic;

  /// Empty payload = a retained message was cleared.
  final Uint8List payload;

  /// Delivered from the broker's retained store (on subscribe).
  final bool retained;

  @override
  String toString() => 'TransportMessage($topic, ${payload.length} bytes, retained: $retained)';
}

class TransportException implements Exception {
  TransportException(this.message);

  final String message;

  @override
  String toString() => 'TransportException: $message';
}

/// Pub/sub transport used by the library. The default implementation is
/// `Mqtt5Transport`; apps may plug in a platform MQTT client instead (e.g. for
/// background operation), and tests use `MemoryTransport`.
///
/// Requirements on implementations: MQTT 5 semantics for retained messages and
/// message expiry, at-least-once delivery, and re-subscription after reconnect
/// (retained messages are then delivered again; consumers are idempotent).
abstract class Transport {
  TransportState get state;

  Stream<TransportState> get states;

  /// Messages for all active subscriptions.
  Stream<TransportMessage> get messages;

  Future<void> connect();

  Future<void> disconnect();

  /// Completes once the broker acknowledged the message. An empty [payload]
  /// with [retain] clears the retained message. [expiry] makes the broker drop
  /// the message (including the retained copy) after that duration.
  Future<void> publish(String topic, Uint8List payload, {bool retain = false, Duration? expiry});

  /// Completes once the broker acknowledged the subscription. Retained messages
  /// matching [filter] are delivered on [messages] afterwards.
  Future<void> subscribe(String filter);

  Future<void> unsubscribe(String filter);
}

/// MQTT topic filter matching (`+` single level, `#` multi level).
bool topicMatches(String filter, String topic) {
  final f = filter.split('/');
  final t = topic.split('/');
  for (var i = 0; i < f.length; i++) {
    if (f[i] == '#') return true;
    if (i >= t.length) return false;
    if (f[i] != '+' && f[i] != t[i]) return false;
  }
  return f.length == t.length;
}
