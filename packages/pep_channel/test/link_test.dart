import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:pep_channel/pep_channel.dart';
import 'package:test/test.dart';

void main() {
  late PepCrypto c;
  late MemoryBroker broker;
  late Identity me;

  setUpAll(() async => c = await PepCrypto.init());
  setUp(() {
    broker = MemoryBroker();
    me = Identity.generate(c);
  });

  KdfParams fast() => KdfParams.generate(c, opsLimit: KdfParams.minOps, memLimit: KdfParams.minMem);
  Uint8List data(String s) => Uint8List.fromList(utf8.encode(s));

  test('request uri round trip and matching codes', () {
    final req = LinkRequest.create(c, broker: 'wss://broker.example:8084');
    expect(req.uri, startsWith('parcoursetpistes://link#'));
    final seen = LinkRequest.parse(req.uri);
    expect(seen.linkId, req.linkId);
    expect(seen.publicKey, req.publicKey);
    expect(seen.broker, 'wss://broker.example:8084');
    expect(seen.topic, req.topic);
    expect(seen.topic, startsWith('pep/v1/link/'));
    expect(seen.code, req.code);
    expect(req.code, matches(RegExp(r'^\d{3} \d{3}$')));
    expect(LinkRequest.create(c).code, isNot(req.code));
    final other = LinkRequest.create(c, topicBase: 'test/pep');
    expect(LinkRequest.parse(other.uri).topicBase, 'test/pep');
    for (final bad in ['https://x', 'parcoursetpistes://join#p=1', 'parcoursetpistes://link#l=AAAA&k=BBBB', '%%']) {
      expect(() => LinkRequest.parse(bad), throwsA(isA<FormatPepException>()), reason: bad);
    }
  });

  test('transfer without password: identity and app data arrive, then are cleared', () async {
    final req = LinkRequest.create(c);
    final newDevice = MemoryTransport(broker);
    final received = req.receive(c, newDevice);
    await LinkRequest.parse(req.uri).send(c, MemoryTransport(broker), me, data: data('{"projects":[]}'));
    final t = await received;
    expect(t.needsPassword, isFalse);
    final got = t.open(c);
    expect(got.identity.id, me.id);
    expect(utf8.decode(got.data), '{"projects":[]}');
    expect(broker.retained.keys.where((k) => k.contains('/link/')), isEmpty, reason: 'cleared after receipt');
    req.dispose();
  });

  test('transfer sent before the new device listens (retained), with a password', () async {
    final req = LinkRequest.create(c);
    await LinkRequest.parse(req.uri).send(c, MemoryTransport(broker), me, password: 'sésame', kdf: fast());
    expect(broker.retained.keys.where((k) => k.contains('/link/')), hasLength(1));
    final t = await req.receive(c, MemoryTransport(broker));
    expect(t.needsPassword, isTrue);
    expect(() => t.open(c), throwsA(isA<WrongPasswordException>()));
    expect(() => t.open(c, password: 'wrong'), throwsA(isA<WrongPasswordException>()));
    final got = t.open(c, password: 'sésame');
    expect(got.identity.id, me.id);
    expect(got.data, isEmpty);
  });

  test('only the requesting device can open it; others are ignored', () async {
    final req = LinkRequest.create(c);
    final intruder = LinkRequest.create(c);
    // Something sealed for another key, published on this request's topic.
    final forOther = LinkRequest.parse(intruder.uri);
    final t = MemoryTransport(broker);
    await t.connect();
    final received = req.receive(c, MemoryTransport(broker), timeout: const Duration(milliseconds: 300));
    await forOther.send(c, MemoryTransport(broker), me); // other topic: never seen
    await t.publish(req.topic, data('garbage'), retain: true);
    await expectLater(received, throwsA(isA<TimeoutException>()));
    expect(() => LinkRequest.parse(req.uri).receive(c, t), throwsStateError);
  });
}
