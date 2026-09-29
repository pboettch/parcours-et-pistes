@Tags(['broker'])
library;

import 'package:pep_core/pep_core.dart';
import 'package:test/test.dart';

import 'support/broker.dart';
import 'support/transport_contract.dart';

void main() {
  if (!isWeb) {
    transportContract('mqtt5 tcp', () => BrokerHarness(Uri.parse(brokerTcp)));
    transportContract('mqtt5 tls (pinned)', () => BrokerHarness(Uri.parse(brokerTls), pins: brokerPins));
  }
  transportContract('mqtt5 websocket', () => BrokerHarness(Uri.parse(brokerWs)));
  // Browser runs use --ignore-certificate-errors (dart_test.yaml); the VM pins.
  transportContract('mqtt5 secure websocket', () => BrokerHarness(Uri.parse(brokerWss), pins: brokerPins));

  group('Mqtt5Transport errors', () {
    Future<void> expectConnectFails(BrokerConfig cfg, [Matcher? message]) async {
      final t = Mqtt5Transport(cfg);
      await expectLater(t.connect(),
          throwsA(isA<TransportException>().having((e) => e.message, 'message', message ?? anything)));
      expect(t.state, TransportState.disconnected);
    }

    test('connection refused (nothing listening)', () async {
      await expectConnectFails(BrokerConfig(Uri.parse(isWeb ? 'ws://127.0.0.1:18999' : 'mqtt://127.0.0.1:18999')));
    });

    test('browsers reject tcp brokers', () async {
      await expectConnectFails(BrokerConfig(Uri.parse(brokerTcp)), contains('ws'));
    }, testOn: 'browser');

    test('unsupported scheme', () async {
      await expectConnectFails(BrokerConfig(Uri.parse('http://127.0.0.1:18883')), contains('http'));
    });

    group('TLS trust', () {
      test('untrusted certificate is refused without a pin', () async {
        await expectConnectFails(BrokerConfig(Uri.parse(brokerTls)));
        await expectConnectFails(BrokerConfig(Uri.parse(brokerWss)));
      });

      test('wrong pin is refused', () async {
        await expectConnectFails(BrokerConfig(Uri.parse(brokerTls), pinnedCertificates: {'00' * 32}));
      });
    }, testOn: 'vm');

    group('authentication and ACL', () {
      test('bad credentials are refused', () async {
        await expectConnectFails(BrokerConfig(Uri.parse(brokerAuth), username: 'pep', password: 'wrong'));
        await expectConnectFails(BrokerConfig(Uri.parse(brokerAuth)));
      });

      test('ACL: allowed topics work, others are refused', () async {
        final t = Mqtt5Transport(BrokerConfig(Uri.parse(brokerAuth), username: 'pep', password: 'pep-secret'));
        await t.connect();
        addTearDown(t.disconnect);
        final inbox = Inbox(t);
        await t.subscribe('pep-acl/allowed/#');
        await t.publish('pep-acl/allowed/x', bytes('ok'));
        await inbox.waitFor((m) => m.isNotEmpty);
        // Denied publish: PUBACK "not authorized" surfaces as an exception.
        await expectLater(t.publish('pep-acl/denied/x', bytes('no')), throwsA(isA<TransportException>()));
        // mosquitto accepts subscriptions to denied topics but delivers nothing
        // (other brokers refuse them in the SUBACK, which also throws).
        final other = Mqtt5Transport(BrokerConfig(Uri.parse(brokerTcp)));
        await other.connect();
        addTearDown(other.disconnect);
        await t.subscribe('pep-acl/denied/#');
        await other.publish('pep-acl/denied/y', bytes('hidden'));
        expect((await inbox.settle()).map((m) => m.topic), ['pep-acl/allowed/x']);
      });
    }, testOn: 'vm');
  });
}
