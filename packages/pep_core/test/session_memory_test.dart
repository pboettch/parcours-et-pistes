import 'dart:typed_data';

import 'package:pep_core/pep_core.dart';

import 'support/session_contract.dart';

class _MemoryHarness implements SessionHarness {
  var _now = DateTime.utc(2026, 9, 29, 10);
  late final broker = MemoryBroker(clock: () => _now);

  @override
  Transport transport() => MemoryTransport(broker);

  @override
  DateTime Function()? get clock => () => _now;

  @override
  void advance(Duration d) => _now = _now.add(d);

  @override
  Map<String, Uint8List>? get retained => broker.retained;

  @override
  List<(String, Uint8List)>? get log => broker.log;
}

void main() => sessionContract('memory', _MemoryHarness.new);
