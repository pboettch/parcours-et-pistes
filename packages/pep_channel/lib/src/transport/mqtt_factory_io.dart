import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mqtt5_client/mqtt5_client.dart';
import 'package:mqtt5_client/mqtt5_server_client.dart';

import 'transport.dart';

/// Dart VM / Flutter mobile & desktop: TCP, TLS, WebSocket and secure WebSocket.
MqttClient createMqttClient(Uri url, String clientId, {Set<String> pinnedCertificates = const {}}) {
  final MqttServerClient c;
  switch (url.scheme) {
    case 'mqtt':
    case 'mqtts':
      c = MqttServerClient.withPort(url.host, clientId, url.hasPort ? url.port : (url.scheme == 'mqtts' ? 8883 : 1883));
      c.secure = url.scheme == 'mqtts';
    case 'ws':
    case 'wss':
      c = MqttServerClient.withPort(
        '${url.scheme}://${url.host}${url.path}',
        clientId,
        url.hasPort ? url.port : (url.scheme == 'wss' ? 443 : 80),
      );
      c.useWebSocket = true;
    default:
      throw TransportException('unsupported broker scheme ${url.scheme}');
  }
  if (pinnedCertificates.isNotEmpty) {
    final pins = {for (final p in pinnedCertificates) p.toLowerCase().replaceAll(':', '')};
    c.onBadCertificate = (dynamic cert) =>
        cert is X509Certificate && pins.contains(sha256.convert(cert.der).toString());
  }
  return c;
}
