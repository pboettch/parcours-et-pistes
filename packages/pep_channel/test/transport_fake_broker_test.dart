@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:pep_channel/pep_channel.dart';
import 'package:test/test.dart';

void main() {
  test('a connect that times out leaves no connection behind, even if the broker answers late', () async {
    // A broker that answers CONNECT only after the client gave up (5 s), then
    // answers pings.
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    var open = 0, pings = 0;
    server.listen((s) {
      open++;
      var first = true;
      s.listen(
        (data) {
          if (first) {
            first = false;
            Timer(const Duration(seconds: 6), () {
              try {
                s.add([0x20, 0x03, 0x00, 0x00, 0x00]); // CONNACK, success
              } catch (_) {}
            });
          } else if (data.isNotEmpty && data[0] == 0xC0) {
            pings++;
            s.add([0xD0, 0x00]); // PINGRESP
          }
        },
        onError: (Object _) {},
        onDone: () {
          open--;
          s.destroy();
        },
      );
    });
    final t = Mqtt5Transport(BrokerConfig(Uri.parse('mqtt://127.0.0.1:${server.port}'), keepAlive: 2));
    await expectLater(t.connect(), throwsA(isA<TransportException>()));
    await t.disconnect();
    await Future<void>.delayed(const Duration(seconds: 3));
    expect(open, 0, reason: 'the abandoned client closed its socket');
    expect(pings, 0);
    await server.close();
  }, timeout: const Timeout(Duration(seconds: 30)));
}
