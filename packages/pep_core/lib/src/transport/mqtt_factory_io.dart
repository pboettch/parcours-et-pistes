import 'package:mqtt5_client/mqtt5_client.dart';
import 'package:mqtt5_client/mqtt5_server_client.dart';

import 'transport.dart';

/// Dart VM / Flutter mobile & desktop: TCP, TLS, WebSocket and secure WebSocket.
MqttClient createMqttClient(Uri url, String clientId) {
  switch (url.scheme) {
    case 'mqtt':
    case 'mqtts':
      final c = MqttServerClient.withPort(url.host, clientId, url.hasPort ? url.port : (url.scheme == 'mqtts' ? 8883 : 1883));
      c.secure = url.scheme == 'mqtts';
      return c;
    case 'ws':
    case 'wss':
      final c = MqttServerClient.withPort(_wsServer(url), clientId, url.hasPort ? url.port : (url.scheme == 'wss' ? 443 : 80));
      c.useWebSocket = true;
      return c;
  }
  throw TransportException('unsupported broker scheme ${url.scheme}');
}

String _wsServer(Uri url) => '${url.scheme}://${url.host}${url.path}';
