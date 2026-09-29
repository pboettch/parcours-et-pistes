import 'dart:convert';
import 'dart:typed_data';

import 'package:pep_core/pep_core.dart';
import 'package:pep_core/src/codec/compression.dart';
import 'package:test/test.dart';

import 'support/crypto.dart';

void main() {
  late PepCrypto c;
  setUpAll(() async => c = await testCrypto());

  group('KdfParams', () {
    test('json round trip', () {
      final p = KdfParams.generate(c);
      final q = KdfParams.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
      expect(q.opsLimit, p.opsLimit);
      expect(q.memLimit, p.memLimit);
      expect(q.salt, p.salt);
    });

    test('rejects hostile params', () {
      final salt = b64u(Uint8List(16));
      expect(() => KdfParams.fromJson({'alg': 'argon2id13', 'ops': 3, 'mem': 1 << 40, 'salt': salt}),
          throwsA(isA<FormatPepException>()));
      expect(() => KdfParams.fromJson({'alg': 'argon2id13', 'ops': 99, 'mem': 1 << 26, 'salt': salt}),
          throwsA(isA<FormatPepException>()));
      expect(() => KdfParams.fromJson({'alg': 'scrypt', 'ops': 3, 'mem': 1 << 26, 'salt': salt}),
          throwsA(isA<FormatPepException>()));
      expect(() => KdfParams.fromJson({'alg': 'argon2id13', 'ops': 3, 'mem': 1 << 26, 'salt': 'AA'}),
          throwsA(isA<FormatPepException>()));
    });
  });

  group('ProjectKey', () {
    test('same password + params → same key check; different password differs', () {
      final p = fastKdf(c);
      final a = ProjectKey.derive(c, 'Trüffel-42', p);
      final b = ProjectKey.derive(c, 'Trüffel-42', p);
      final x = ProjectKey.derive(c, 'Trüffel-43', p);
      expect(a.check, b.check);
      expect(a.check, isNot(x.check));
      expect(a.dataKey.extractBytes(), b.dataKey.extractBytes());
      for (final k in [a, b, x]) {
        k.dispose();
      }
    });

    test('default params derive in reasonable time', () {
      final sw = Stopwatch()..start();
      ProjectKey.derive(c, 'password', KdfParams.generate(c)).dispose();
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
    });
  });

  group('Identity', () {
    test('seed export/import keeps the same public key', () {
      final a = Identity.generate(c);
      final b = Identity.fromSeed(c, a.exportSeed());
      expect(b.publicKey, a.publicKey);
      expect(b.id, a.id);
      expect(publicKeyFromId(a.id), a.publicKey);
      expect(a.id, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
    });

    test('sign / verify', () {
      final a = Identity.generate(c);
      final msg = Uint8List.fromList([1, 2, 3]);
      final sig = a.sign(msg);
      expect(Identity.verify(c, msg, sig, a.publicKey), isTrue);
      expect(Identity.verify(c, Uint8List.fromList([1, 2, 4]), sig, a.publicKey), isFalse);
      expect(Identity.verify(c, msg, sig, Identity.generate(c).publicKey), isFalse);
      expect(Identity.verify(c, msg, Uint8List(3), a.publicKey), isFalse);
    });
  });

  group('Envelope', () {
    late ProjectKey key;
    late Identity me;
    late Envelope env;
    const topic = 'pep/v1/abc/track/t1';

    setUpAll(() {
      key = ProjectKey.derive(c, 'secret', fastKdf(c));
      me = Identity.generate(c);
      env = Envelope(c);
    });

    final big = Uint8List.fromList(utf8.encode('<gpx>${'<trkpt lat="45.1" lon="5.7"/>' * 500}</gpx>'));

    test('round trip, compressed payload is much smaller', () {
      final sealed = env.seal(key: key.dataKey, topic: topic, body: big, signer: me);
      expect(sealed.length, lessThan(big.length ~/ 10));
      final o = env.open(key: key.dataKey, topic: topic, data: sealed);
      expect(o.body, big);
      expect(o.signer, me.publicKey);
      expect(o.signerId, me.id);
    });

    test('small and empty bodies', () {
      for (final body in [Uint8List(0), Uint8List.fromList([42])]) {
        final sealed = env.seal(key: key.dataKey, topic: topic, body: body, signer: me);
        expect(env.open(key: key.dataKey, topic: topic, data: sealed).body, body);
      }
    });

    test('ciphertext does not leak plaintext and nonces differ', () {
      final body = utf8Bytes('Secret trail near the old mill');
      final a = env.seal(key: key.dataKey, topic: topic, body: body, signer: me, compress: false);
      final b = env.seal(key: key.dataKey, topic: topic, body: body, signer: me, compress: false);
      expect(latin1.decode(a).contains('Secret'), isFalse);
      expect(a, isNot(b));
    });

    test('wrong key fails', () {
      final other = ProjectKey.derive(c, 'other', fastKdf(c));
      final sealed = env.seal(key: key.dataKey, topic: topic, body: big, signer: me);
      expect(() => env.open(key: other.dataKey, topic: topic, data: sealed),
          throwsA(isA<DecryptionException>()));
    });

    test('wrong topic fails (no replay onto another topic)', () {
      final sealed = env.seal(key: key.dataKey, topic: topic, body: big, signer: me);
      expect(() => env.open(key: key.dataKey, topic: 'pep/v1/abc/track/t2', data: sealed),
          throwsA(isA<DecryptionException>()));
    });

    test('every flipped byte is detected', () {
      final sealed = env.seal(key: key.dataKey, topic: topic, body: utf8Bytes('hello world'), signer: me);
      for (var i = 0; i < sealed.length; i++) {
        final t = Uint8List.fromList(sealed)..[i] ^= 0x01;
        expect(() => env.open(key: key.dataKey, topic: topic, data: t),
            throwsA(isA<PepException>()), reason: 'byte $i');
      }
    });

    test('truncated / garbage input', () {
      final sealed = env.seal(key: key.dataKey, topic: topic, body: big, signer: me);
      for (final bad in [Uint8List(0), Uint8List.sublistView(sealed, 0, 10), utf8Bytes('hello')]) {
        expect(() => env.open(key: key.dataKey, topic: topic, data: bad),
            throwsA(isA<PepException>()));
      }
    });
  });

  group('compression', () {
    test('rejects deflate bombs', () {
      final z = deflate(Uint8List(1024 * 1024));
      expect(inflate(z).length, 1024 * 1024);
      expect(() => inflate(z, maxSize: 1000), throwsA(isA<FormatPepException>()));
    });

    test('rejects corrupt or truncated data', () {
      final z = deflate(utf8Bytes('hello hello hello hello hello'));
      for (final bad in [
        Uint8List.fromList([0, 0, 0, 5, 0xff, 0xff, 0xff, 0xff]),
        Uint8List.sublistView(z, 0, z.length - 3),
        Uint8List.fromList([1, 2]),
        Uint8List.fromList([0xff, 0xff, 0xff, 0xff, 0]), // hostile size, must not wrap negative
      ]) {
        expect(() => inflate(bad), throwsA(isA<FormatPepException>()));
      }
      expect(inflate(deflate(Uint8List(0))), isEmpty);
    });
  });
}
