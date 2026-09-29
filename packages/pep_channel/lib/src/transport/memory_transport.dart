import 'dart:async';
import 'dart:typed_data';

import 'transport.dart';

/// In-process MQTT-like broker for tests: retained messages, message expiry
/// (with an injectable clock) and wildcard subscriptions.
class MemoryBroker {
  MemoryBroker({DateTime Function()? clock}) : now = clock ?? DateTime.now;

  DateTime Function() now;

  final _retained = <String, (Uint8List, DateTime?)>{};
  final _clients = <MemoryTransport>{};

  /// Every publish seen by the broker (topic, payload), for assertions.
  final log = <(String, Uint8List)>[];

  /// Retained payloads currently stored (expired ones removed).
  Map<String, Uint8List> get retained {
    _expire();
    return {for (final e in _retained.entries) e.key: e.value.$1};
  }

  void _expire() {
    final n = now();
    _retained.removeWhere((_, v) => v.$2 != null && !v.$2!.isAfter(n));
  }

  void _publish(String topic, Uint8List payload, bool retain, Duration? expiry) {
    log.add((topic, payload));
    if (retain) {
      if (payload.isEmpty) {
        _retained.remove(topic);
      } else {
        _retained[topic] = (payload, expiry == null ? null : now().add(expiry));
      }
    }
    for (final c in _clients) {
      if (c._subscriptions.any((f) => topicMatches(f, topic))) {
        c._deliver(TransportMessage(topic, payload));
      }
    }
  }

  void _subscribe(MemoryTransport c, String filter) {
    _expire();
    for (final e in _retained.entries) {
      if (topicMatches(filter, e.key)) {
        c._deliver(TransportMessage(e.key, e.value.$1, retained: true));
      }
    }
  }
}

class MemoryTransport implements Transport {
  MemoryTransport(this.broker);

  final MemoryBroker broker;
  final _subscriptions = <String>{};
  final _messages = StreamController<TransportMessage>.broadcast();
  final _states = StreamController<TransportState>.broadcast();
  var _state = TransportState.disconnected;

  @override
  TransportState get state => _state;

  @override
  Stream<TransportState> get states => _states.stream;

  @override
  Stream<TransportMessage> get messages => _messages.stream;

  void _setState(TransportState s) {
    _state = s;
    _states.add(s);
  }

  void _checkConnected() {
    if (_state != TransportState.connected) throw TransportException('not connected');
  }

  void _deliver(TransportMessage m) => scheduleMicrotask(() {
        if (_state == TransportState.connected) _messages.add(m);
      });

  @override
  Future<void> connect() async {
    broker._clients.add(this);
    _setState(TransportState.connected);
  }

  @override
  Future<void> disconnect() async {
    broker._clients.remove(this);
    _subscriptions.clear();
    _setState(TransportState.disconnected);
  }

  @override
  Future<void> publish(String topic, Uint8List payload, {bool retain = false, Duration? expiry}) async {
    _checkConnected();
    if (topic.contains(RegExp(r'[#+]'))) throw TransportException('invalid topic $topic');
    broker._publish(topic, payload, retain, expiry);
  }

  @override
  Future<void> subscribe(String filter) async {
    _checkConnected();
    _subscriptions.add(filter);
    broker._subscribe(this, filter);
  }

  @override
  Future<void> unsubscribe(String filter) async {
    _subscriptions.remove(filter);
  }
}
