import 'dart:async';
import 'dart:typed_data';

import 'package:pep_channel/pep_channel.dart';
import 'package:test/test.dart';

/// Creates connected-ready transports for one test and advances time by a
/// duration (real sleep for real brokers, clock skip for the memory broker).
abstract class TransportHarness {
  Transport create();
  Future<void> advance(Duration d);
}

/// Collects messages from a transport.
class Inbox {
  Inbox(Transport t) {
    _sub = t.messages.listen((m) {
      messages.add(m);
      _changed.add(null);
    });
  }

  final messages = <TransportMessage>[];
  final _changed = StreamController<void>.broadcast();
  late final StreamSubscription<TransportMessage> _sub;

  Future<List<TransportMessage>> waitFor(bool Function(List<TransportMessage>) cond,
      {Duration timeout = const Duration(seconds: 5)}) async {
    final deadline = DateTime.now().add(timeout);
    while (!cond(messages)) {
      final left = deadline.difference(DateTime.now());
      if (left.isNegative) throw TimeoutException('condition not met; got $messages');
      await _changed.stream.first.timeout(left, onTimeout: () {});
    }
    return messages;
  }

  /// Waits a little and returns what arrived (to assert that nothing arrives).
  Future<List<TransportMessage>> settle([Duration d = const Duration(milliseconds: 300)]) async {
    await Future<void>.delayed(d);
    return messages;
  }

  Future<void> close() => _sub.cancel();
}

Uint8List bytes(String s) => utf8Bytes(s);

void transportContract(String name, TransportHarness Function() harness, {String prefix = 'pep-test'}) {
  group('Transport contract: $name', () {
    late TransportHarness h;
    late String base;
    final open = <Transport>[];
    var n = 0;

    Future<Transport> connected() async {
      final t = h.create();
      open.add(t);
      await t.connect();
      return t;
    }

    setUp(() {
      h = harness();
      base = '$prefix/${DateTime.now().microsecondsSinceEpoch}-${n++}';
    });

    tearDown(() async {
      for (final t in open) {
        await t.disconnect();
      }
      open.clear();
    });

    test('connect / disconnect states', () async {
      final t = h.create();
      open.add(t);
      expect(t.state, TransportState.disconnected);
      await t.connect();
      expect(t.state, TransportState.connected);
      await t.disconnect();
      expect(t.state, TransportState.disconnected);
      expect(() => t.publish('$base/x', bytes('x')), throwsA(isA<TransportException>()));
    });

    test('live publish reaches subscriber', () async {
      final a = await connected(), b = await connected();
      final inbox = Inbox(b);
      await b.subscribe('$base/#');
      await a.publish('$base/live', bytes('hello'));
      final got = await inbox.waitFor((m) => m.isNotEmpty);
      expect(got.single.topic, '$base/live');
      expect(got.single.payload, bytes('hello'));
      expect(got.single.retained, isFalse);
    });

    test('retained: delivered on subscribe, replaced, cleared', () async {
      final a = await connected();
      await a.publish('$base/r', bytes('v1'), retain: true);
      await a.publish('$base/r', bytes('v2'), retain: true);
      await a.publish('$base/other', bytes('o'), retain: true);

      final b = await connected();
      final inbox = Inbox(b);
      await b.subscribe('$base/#');
      final got = await inbox.waitFor((m) => m.length >= 2);
      expect({for (final m in got) m.topic: String.fromCharCodes(m.payload)},
          {'$base/r': 'v2', '$base/other': 'o'});
      expect(got.every((m) => m.retained), isTrue);

      await a.publish('$base/r', Uint8List(0), retain: true);
      await a.publish('$base/other', Uint8List(0), retain: true);
      final c = await connected();
      final inbox2 = Inbox(c);
      await c.subscribe('$base/#');
      expect(await inbox2.settle(), isEmpty);
    });

    test('retained message expiry', () async {
      final a = await connected();
      await a.publish('$base/pos', bytes('p'), retain: true, expiry: const Duration(seconds: 1));
      await a.publish('$base/keep', bytes('k'), retain: true);
      await h.advance(const Duration(milliseconds: 2200));
      final b = await connected();
      final inbox = Inbox(b);
      await b.subscribe('$base/#');
      final got = await inbox.waitFor((m) => m.isNotEmpty);
      await inbox.settle();
      expect(got.map((m) => m.topic), ['$base/keep']);
      await a.publish('$base/keep', Uint8List(0), retain: true);
    });

    test('single-level wildcard and unsubscribe', () async {
      final a = await connected(), b = await connected();
      final inbox = Inbox(b);
      await b.subscribe('$base/+/x');
      await a.publish('$base/1/x', bytes('1'));
      await a.publish('$base/2/y', bytes('2'));
      await a.publish('$base/3/x', bytes('3'));
      await inbox.waitFor((m) => m.length >= 2);
      expect((await inbox.settle()).map((m) => m.topic), ['$base/1/x', '$base/3/x']);
      await b.unsubscribe('$base/+/x');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await a.publish('$base/4/x', bytes('4'));
      expect((await inbox.settle()).length, 2);
    });

    test('large payload (2 MiB)', () async {
      final a = await connected(), b = await connected();
      final inbox = Inbox(b);
      await b.subscribe('$base/big');
      final big = Uint8List.fromList(List.generate(2 << 20, (i) => i * 7 & 0xff));
      await a.publish('$base/big', big);
      final got = await inbox.waitFor((m) => m.isNotEmpty, timeout: const Duration(seconds: 20));
      expect(got.single.payload, big);
    });
  });
}

/// Harness for the in-memory broker.
class MemoryHarness implements TransportHarness {
  final broker = MemoryBroker(clock: () => _now);
  static DateTime _now = DateTime.utc(2026);

  @override
  Transport create() => MemoryTransport(broker);

  @override
  Future<void> advance(Duration d) async => _now = _now.add(d);
}

/// Harness for a real broker.
class BrokerHarness implements TransportHarness {
  BrokerHarness(this.url, {this.pins = const {}});

  final Uri url;
  final Set<String> pins;

  @override
  Transport create() => Mqtt5Transport(BrokerConfig(url, pinnedCertificates: pins));

  @override
  Future<void> advance(Duration d) => Future<void>.delayed(d);
}
