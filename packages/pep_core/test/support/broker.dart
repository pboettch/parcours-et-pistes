/// Local development broker (see tools/broker, .claude/scripts/broker.sh).
/// Override with PEP_TEST_BROKER_TCP / PEP_TEST_BROKER_WS when running on the VM.
const brokerTcp = String.fromEnvironment('PEP_TEST_BROKER_TCP', defaultValue: 'mqtt://127.0.0.1:18883');
const brokerWs = String.fromEnvironment('PEP_TEST_BROKER_WS', defaultValue: 'ws://127.0.0.1:18080');
