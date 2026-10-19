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
    this.keepAlive = 60,
    this.pinnedCertificates = const {},
  });

  /// `mqtt://host[:1883]`, `mqtts://host[:8883]`, `ws://host[:port]/path`,
  /// `wss://host[:port]/path`. Browsers support only ws/wss.
  final Uri url;
  final String? username;
  final String? password;

  /// MQTT client id; a new random one per connection when null. A fixed one
  /// must be unique: the broker drops the older of two connections with the
  /// same id, and both would keep reconnecting.
  final String? clientId;

  /// Keep-alive interval in seconds (sent to the broker; a connection that
  /// does not answer pings within it is dropped). Browsers throttle timers in
  /// background tabs: keep it at a minute or more.
  final int keepAlive;

  /// SHA-256 fingerprints (lowercase hex of the DER encoding) of server
  /// certificates accepted even when they do not chain to a trusted root, e.g.
  /// a self-hosted broker with a self-signed certificate. Dart VM only
  /// (mqtts/wss); in browsers, certificate trust is up to the browser.
  final Set<String> pinnedCertificates;
}

/// [Transport] backed by `mqtt5_client` (MQTT 5, QoS 1, auto-reconnect with
/// automatic re-subscription). A connection that stops answering (no ping
/// response within the keep-alive period) is dropped and re-established; so is
/// one the broker closes, with a growing delay.
///
/// mqtt5_client may report a socket reset by the broker as an uncaught error:
/// run the app (or CLI) in a zone that handles uncaught errors.
class Mqtt5Transport implements Transport {
  Mqtt5Transport(this.config, {String Function()? clientIdGenerator})
    : _newClientId = clientIdGenerator ?? _randomClientId;

  final BrokerConfig config;
  final String Function() _newClientId;

  /// Client id of the current connection: [BrokerConfig.clientId], else a new
  /// one per [connect] — the previous connection may not be closed yet at the
  /// broker, which would take it over and reset it.
  late String _clientId;
  MqttClient? _client;

  final _messages = StreamController<TransportMessage>.broadcast();
  final _states = StreamController<TransportState>.broadcast();
  var _state = TransportState.disconnected;
  final _pendingPublish = <int, Completer<void>>{};
  final _pendingSubscribe = <String, Completer<void>>{};

  /// Filters the broker confirmed on the current connection.
  final _subscribed = <String>{};
  final _subs = <StreamSubscription<dynamic>>[];

  final _pendingUnsubscribe = <String, Completer<void>>{};

  /// Connected on request and not disconnected since: reconnect after a
  /// broker-side disconnect.
  var _wanted = false;
  Timer? _reconnectTimer;
  var _backoff = const Duration(seconds: 1);
  DateTime? _connectedAt;

  /// The connection being opened (shared by concurrent [connect] calls), and
  /// how [disconnect] aborts it.
  Future<void>? _connecting;
  void Function()? _abortConnect;

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

  /// Connects (concurrent calls share one attempt). Once connected, the
  /// transport reconnects by itself until [disconnect] — also after a later
  /// failed [connect]: a transport given up on must be disconnected.
  @override
  Future<void> connect() {
    _wanted = true;
    _reconnectTimer?.cancel();
    final pending = _connecting;
    if (pending != null) return pending;
    if (_client != null) {
      if (_state == TransportState.connected) return Future.value();
      // The client is reconnecting by itself.
      return states
          .firstWhere((s) => s == TransportState.connected)
          .timeout(const Duration(seconds: 30), onTimeout: () => throw TransportException('still reconnecting'));
    }
    final f = _open();
    _connecting = f;
    f.then((_) {}, onError: (Object _) {}).whenComplete(() {
      if (identical(_connecting, f)) _connecting = null;
    });
    return f;
  }

  Future<void> _open() async {
    _clientId = config.clientId ?? _newClientId();
    final c = createMqttClient(config.url, _clientId, pinnedCertificates: config.pinnedCertificates);
    bool current() => identical(_client, c);
    c
      ..logging(on: false)
      ..keepAlivePeriod = config.keepAlive
      ..disconnectOnNoResponsePeriod = config.keepAlive
      ..autoReconnect = true
      ..resubscribeOnAutoReconnect = true
      ..onConnected = (() {
        if (current()) _setState(TransportState.connected);
      })
      ..onAutoReconnect = (() {
        if (!current()) return;
        _failPublishes();
        _subscribed.clear(); // re-subscribed by the client, confirmed again
        _setState(TransportState.connecting);
      })
      ..onAutoReconnected = (() {
        if (current()) _setState(TransportState.connected);
      })
      ..onDisconnected = (() => _onDisconnected(c))
      ..onSubscribed = ((sub) {
        if (!current()) return;
        if (sub.topic.rawTopic case final t?) _subscribed.add(t);
        _pendingSubscribe.remove(sub.topic.rawTopic)?.complete();
      })
      ..onSubscribeFail = ((sub) {
        if (!current()) return;
        _pendingSubscribe
            .remove(sub.topic.rawTopic)
            ?.completeError(TransportException('subscription to ${sub.topic.rawTopic} refused'));
      })
      ..onUnsubscribed = ((sub) {
        if (!current()) return;
        _subscribed.remove(sub.topic.rawTopic);
        _pendingUnsubscribe.remove(sub.topic.rawTopic)?.complete();
      });
    // The broker drops a client silent for 1.5 × the announced keep-alive;
    // announcing twice the ping period leaves room for throttled timers.
    c.connectionMessage = MqttConnectMessage()
        .withClientIdentifier(_clientId)
        .keepAliveFor(config.keepAlive * 2)
        .startClean();
    _client = c;
    _setState(TransportState.connecting);
    final status = Completer<MqttConnectionStatus?>();
    var aborted = false;
    void abort() {
      aborted = true;
      if (!status.isCompleted) status.completeError(TransportException('disconnected while connecting'));
    }

    _abortConnect = abort;
    unawaited(
      c
          .connect(config.username, config.password)
          .then(
            (r) {
              if (aborted) {
                _drop(c); // disconnect() was called meanwhile
              } else if (!status.isCompleted) {
                status.complete(r);
              }
            },
            onError: (Object e) {
              if (aborted) _drop(c);
              if (!status.isCompleted) status.completeError(e);
            },
          ),
    );
    final MqttConnectionStatus? result;
    try {
      result = await status.future;
    } catch (e) {
      if (identical(_abortConnect, abort)) _abortConnect = null;
      if (current()) _teardown();
      // E.g. timed out: a late answer must not bring this client to life.
      if (!aborted) _drop(c);
      if (!aborted) _retryLater();
      throw e is TransportException ? e : TransportException('cannot connect to ${config.url}: $e');
    }
    if (identical(_abortConnect, abort)) _abortConnect = null;
    if (result?.state != MqttConnectionState.connected) {
      _teardown();
      _drop(c);
      _retryLater();
      throw TransportException('connection refused: ${result?.reasonCode} ${result?.reasonString ?? ''}');
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
    _connectedAt = DateTime.now();
    _setState(TransportState.connected);
  }

  /// A failed connect of a transport that was connected before (e.g. the app
  /// reconnecting while the broker restarts) keeps trying in the background.
  void _retryLater() {
    if (_wanted && _connectedAt != null) _scheduleReconnect();
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

  /// Not asked for (e.g. the broker closed the connection): start over with a
  /// new client, after a growing delay.
  void _onDisconnected(MqttClient c) {
    if (!identical(_client, c)) return;
    c.autoReconnect = false;
    // Back to a short delay only after a connection that lasted.
    final at = _connectedAt;
    if (at != null && DateTime.now().difference(at) > const Duration(minutes: 1)) _backoff = const Duration(seconds: 1);
    _teardown();
    if (_wanted) _scheduleReconnect();
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    final delay = _backoff;
    final next = _backoff * 2;
    _backoff = next > const Duration(seconds: 30) ? const Duration(seconds: 30) : next;
    _reconnectTimer = Timer(delay, () {
      if (!_wanted || _client != null) return;
      // a failure schedules the next attempt (see _retryLater)
      connect().then((_) {}, onError: (Object _) {});
    });
  }

  /// The session restarts clean after a reconnect: acknowledgements of
  /// publishes in flight will never come, so their callers get an error (the
  /// message may or may not have reached the broker).
  void _failPublishes() {
    final err = TransportException('disconnected before the broker acknowledged the publish');
    final pending = [..._pendingPublish.values];
    _pendingPublish.clear();
    for (final p in pending) {
      p.completeError(err);
    }
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
    for (final u in _pendingUnsubscribe.values) {
      u.complete();
    }
    _pendingPublish.clear();
    _pendingSubscribe.clear();
    _pendingUnsubscribe.clear();
    _subscribed.clear();
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
    _wanted = false;
    _reconnectTimer?.cancel();
    final abort = _abortConnect;
    if (abort != null) {
      // Connecting: the client disconnects itself once its connect settled.
      abort();
      _connecting = null;
      _teardown();
      return;
    }
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

  /// Completes at once for a filter already confirmed on this connection
  /// (the client sends nothing for it, so no confirmation would come); waits
  /// for a pending unsubscribe of the same filter first. One subscriber per
  /// filter: a second `SecureChannel` of the same channel needs its own
  /// transport.
  @override
  Future<void> subscribe(String filter) async {
    final leaving = _pendingUnsubscribe[filter];
    if (leaving != null) await leaving.future.timeout(const Duration(seconds: 10), onTimeout: () {});
    final c = _connected();
    if (_subscribed.contains(filter)) return;
    final pending = _pendingSubscribe[filter];
    if (pending != null) return pending.future;
    final done = _pendingSubscribe[filter] = Completer<void>();
    if (c.subscribe(filter, MqttQos.atLeastOnce) == null) {
      _pendingSubscribe.remove(filter);
      throw TransportException('cannot subscribe to $filter');
    }
    return done.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        if (identical(_pendingSubscribe[filter], done)) _pendingSubscribe.remove(filter);
        final e = TransportException('subscription to $filter not confirmed');
        if (!done.isCompleted) done.completeError(e); // for callers sharing it
        throw e;
      },
    );
  }

  /// Completes when the broker confirmed it (or after 10 s).
  @override
  Future<void> unsubscribe(String filter) async {
    _subscribed.remove(filter);
    final c = _client;
    if (c == null || _state != TransportState.connected) return;
    final done = _pendingUnsubscribe.putIfAbsent(filter, Completer<void>.new);
    c.unsubscribeStringTopic(filter);
    await done.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        if (identical(_pendingUnsubscribe[filter], done)) _pendingUnsubscribe.remove(filter);
      },
    );
  }

  /// Closes a client given up on (its socket and keep-alive), best effort:
  /// `disconnect()` alone closes nothing while the client is not connected.
  static void _drop(MqttClient c) {
    try {
      c.autoReconnect = false;
      c.disconnectOnNoPingResponse(DisconnectOnNoPingResponse()); // closes the socket
      c.disconnect(); // stops the keep-alive
    } catch (_) {
      // already closed
    }
  }

  static final _rnd = Random.secure();

  static String _randomClientId() => 'pep-${List.generate(12, (_) => _rnd.nextInt(36).toRadixString(36)).join()}';
}
