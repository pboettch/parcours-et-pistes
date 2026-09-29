import 'package:mqtt5_client/mqtt5_browser_client.dart';
import 'package:mqtt5_client/mqtt5_client.dart';

import 'transport.dart';

/// Browser: only WebSocket (ws/wss) is possible.
MqttClient createMqttClient(Uri url, String clientId, {Set<String> pinnedCertificates = const {}}) {
  if (url.scheme != 'ws' && url.scheme != 'wss') {
    throw TransportException('browsers only support ws:// and wss:// brokers, not ${url.scheme}');
  }
  return MqttBrowserClient.withPort('${url.scheme}://${url.host}${url.path}', clientId,
      url.hasPort ? url.port : (url.scheme == 'wss' ? 443 : 80));
}
