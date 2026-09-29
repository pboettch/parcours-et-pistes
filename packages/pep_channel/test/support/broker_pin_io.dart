import 'dart:io';

Set<String> brokerPins() {
  final f = File('../../tools/broker/certs/server.sha256');
  return f.existsSync() ? {f.readAsStringSync().trim()} : const {};
}
