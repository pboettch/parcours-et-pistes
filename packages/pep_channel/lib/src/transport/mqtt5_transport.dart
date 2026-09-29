import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:mqtt5_client/mqtt5_client.dart';
import 'package:typed_data/typed_buffers.dart';

import 'mqtt_factory.dart'
    if (dart.library.io) 'mqtt_factory_io.dart'
    if (dart.library.js_interop) 'mqtt_factory_web.dart';
import 'transport.dart';

/// Broker connection settings.
class BrokerConfig {
  BrokerConfig(
    this.url, {
    this.username,
    this.password,
    this.clientId,
    this.keepAlive = 30,
    this.pinnedCertificates = const {},
  });

  /// `mqtt://host[:1883]`, `mqtts://host[:8883]`, `ws://host[:port]/path`,
  /// `wss://host[:port]/path`. Browsers support only ws/wss.
  final Uri url;
  final String? username;
  final String? password;

  /// MQTT client id; a random one is used when null.
  final String? clientId;

  /// Keep-alive interval in seconds.
  final int keepAlive;

  /// SHA-256 fingerprints (lowercase hex of the DER encoding) of server
  /// certificates accepted even when they do not chain to a trusted root, e.g.
  /// a self-hosted broker with a self-signed certificate. Dart VM only
  /// (mqtts/wss); in browsers, certificate trust is up to the browser.
  final Set<String> pinnedCertificates;
}

/// [Transport] backed by `mqtt5_client` (MQTT 5, QoS 1, auto-reconnect with
/// automatic re-subscription).
class Mqtt5Transport implements Transport {
  Mqtt5Transport(this.config, {String Function()? clientIdGenerator})
    : _clientId = config.clientId ?? (clientIdGenerator ?? _randomClientId)();

  final BrokerConfig config;
  final String _clientId;
  MqttClient? _client;

  final _messages = StreamController<TransportMessage>.broadcast();
  final _states = StreamController<TransportState>.broadcast();
  var _state = TransportState.disconnected;
  final _pendingPublish = <int, Completer<void>>{};
  final _pendingSubscribe = <String, Completer<void>>{};
  final _subs = <StreamSubscription<dynamic>>[];

  @override
  TransportState get state => _state;

  @override
  Stream<TransportState> get states => _states.stream;

  @override
  Stream<TransportMessage> get messages => _messages.stream;

  void _setState(TransportState s) {
    if (s == _state) return;
    _state = s;
    _states.add(s);
  }

  @override
  Future<void> connect() async {
    if (_client != null) return;
    final c = createMqttClient(config.url, _clientId, pinnedCertificates: config.pinnedCertificates)
      ..logging(on: false)
      ..keepAlivePeriod = config.keepAlive
      ..autoReconnect = true
      ..resubscribeOnAutoReconnect = true
      ..onConnected = (() => _setState(TransportState.connected))
      ..onAutoReconnect = (() => _setState(TransportState.connecting))
      ..onAutoReconnected = (() => _setState(TransportState.connected))
      ..onDisconnected = _onDisconnected
      ..onSubscribed = ((s) => _pendingSubscribe.remove(s.topic.rawTopic)?.complete())
      ..onSubscribeFail = ((s) => _pendingSubscribe
          .remove(s.topic.rawTopic)
          ?.completeError(TransportException('subscription to ${s.topic.rawTopic} refused')));
    c.connectionMessage = MqttConnectMessage().withClientIdentifier(_clientId).startClean();
    _client = c;
    _setState(TransportState.connecting);
    try {
      final status = await c.connect(config.username, config.password);
      if (status?.state != MqttConnectionState.connected) {
        throw TransportException('connection refused: ${status?.reasonCode} ${status?.reasonString ?? ''}');
      }
    } catch (e) {
      _teardown();
      throw e is TransportException ? e : TransportException('cannot connect to ${config.url}: $e');
    }
    _subs
      ..add(c.updates!.listen(_onUpdates))
      ..add(c.published!.listen((m) => _pendingPublish.remove(m.variableHeader!.messageIdentifier)?.complete()))
      ..add(
        c.publishFail!.listen(
          (ack) => _pendingPublish
              .remove(ack.variableHeader!.messageIdentifier)
              ?.completeError(TransportException('publish refused: ${ack.reasonCode}')),
        ),
      );
    _setState(TransportState.connected);
  }

  void _onUpdates(List<MqttReceivedMessage<MqttMessage>> batch) {
    for (final r in batch) {
      final m = r.payload;
      if (m is! MqttPublishMessage || r.topic == null) continue;
      final data = m.payload.message;
      _messages.add(
        TransportMessage(
          r.topic!,
          data == null ? Uint8List(0) : Uint8List.fromList(data),
          retained: m.header?.retain ?? false,
        ),
      );
    }
  }

  void _onDisconnected() {
    if (_client == null) return;
    _setState(TransportState.disconnected);
  }

  void _teardown() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    final err = TransportException('disconnected');
    for (final p in [..._pendingPublish.values, ..._pendingSubscribe.values]) {
      p.completeError(err);
    }
    _pendingPublish.clear();
    _pendingSubscribe.clear();
    _client = null;
    _setState(TransportState.disconnected);
  }

  MqttClient _connected() {
    final c = _client;
    if (c == null || _state != TransportState.connected) throw TransportException('not connected');
    return c;
  }

  @override
  Future<void> disconnect() async {
    final c = _client;
    if (c == null) return;
    _client = null; // suppress auto-reconnect handling in callbacks
    c.autoReconnect = false;
    c.disconnect();
    _client = c;
    _teardown();
  }

  @override
  Future<void> publish(String topic, Uint8List payload, {bool retain = false, Duration? expiry}) {
    final c = _connected();
    final msg = MqttPublishMessage()
        .toTopic(topic)
        .withQos(MqttQos.atLeastOnce)
        .publishData(Uint8Buffer()..addAll(payload));
    msg.setRetain(state: retain);
    if (expiry != null) msg.withMessageExpiryInterval(expiry.inSeconds.clamp(1, 0xffffffff));
    final done = Completer<void>();
    final id = c.publishUserMessage(msg);
    _pendingPublish[id] = done;
    return done.future;
  }

  @override
  Future<void> subscribe(String filter) {
    final c = _connected();
    final done = _pendingSubscribe.putIfAbsent(filter, Completer<void>.new);
    if (c.subscribe(filter, MqttQos.atLeastOnce) == null) {
      _pendingSubscribe.remove(filter);
      return Future.error(TransportException('cannot subscribe to $filter'));
    }
    return done.future;
  }

  @override
  Future<void> unsubscribe(String filter) async {
    _client?.unsubscribeStringTopic(filter);
  }

  static final _rnd = Random.secure();

  static String _randomClientId() => 'pep-${List.generate(12, (_) => _rnd.nextInt(36).toRadixString(36)).join()}';
}
