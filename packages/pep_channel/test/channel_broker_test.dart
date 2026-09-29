@Tags(['broker'])
library;

import 'dart:typed_data';

import 'package:pep_channel/pep_channel.dart';
import 'package:test/test.dart';

import 'support/broker.dart';
import 'support/channel_contract.dart';

class _BrokerHarness implements ChannelHarness {
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
  channelContract('mqtt5 ${isWeb ? 'websocket' : 'tcp'}', () => _BrokerHarness(Uri.parse(isWeb ? brokerWs : brokerTcp)));
}
