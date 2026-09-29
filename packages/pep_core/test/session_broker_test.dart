@Tags(['broker'])
library;

import 'dart:typed_data';

import 'package:pep_core/pep_core.dart';
import 'package:test/test.dart';

import 'support/broker.dart';
import 'support/session_contract.dart';

const _isWeb = bool.fromEnvironment('dart.library.js_interop');

class _BrokerHarness implements SessionHarness {
  _BrokerHarness(this.url);

  final Uri url;

  @override
  Transport transport() => Mqtt5Transport(BrokerConfig(url));

  @override
  DateTime Function()? get clock => null;

  @override
  void advance(Duration d) => throw UnsupportedError('real clock');

  @override
  Map<String, Uint8List>? get retained => null;

  @override
  List<(String, Uint8List)>? get log => null;
}

void main() {
  sessionContract('mqtt5 ${_isWeb ? 'websocket' : 'tcp'}',
      () => _BrokerHarness(Uri.parse(_isWeb ? brokerWs : brokerTcp)));
}
