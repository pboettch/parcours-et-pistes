@Tags(['broker'])
library;

import 'package:test/test.dart';

import 'support/broker.dart';
import 'support/transport_contract.dart';

const _isWeb = bool.fromEnvironment('dart.library.js_interop');

void main() {
  if (!_isWeb) transportContract('mqtt5 tcp', () => BrokerHarness(Uri.parse(brokerTcp)));
  transportContract('mqtt5 websocket', () => BrokerHarness(Uri.parse(brokerWs)));
}
