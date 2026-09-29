import 'broker_pin_stub.dart' if (dart.library.io) 'broker_pin_io.dart' as pin;

/// Local development broker (see tools/broker, .claude/scripts/broker.sh).
const brokerTcp = String.fromEnvironment('PEP_TEST_BROKER_TCP', defaultValue: 'mqtt://127.0.0.1:18883');
const brokerWs = String.fromEnvironment('PEP_TEST_BROKER_WS', defaultValue: 'ws://127.0.0.1:18080');
const brokerTls = 'mqtts://127.0.0.1:18884';
const brokerWss = 'wss://127.0.0.1:18443';

/// Authenticated listener: user "pep" / "pep-secret", read/write only below pep-acl/allowed/.
const brokerAuth = 'mqtt://127.0.0.1:18885';

const isWeb = bool.fromEnvironment('dart.library.js_interop');

/// SHA-256 pin of the dev broker's test certificate (VM only; empty on the web).
Set<String> get brokerPins => pin.brokerPins();
