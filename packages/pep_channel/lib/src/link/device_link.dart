import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:sodium/sodium_sumo.dart';

import '../codec/bytes.dart';
import '../crypto/identity.dart';
import '../crypto/kdf.dart';
import '../crypto/pep_crypto.dart';
import '../errors.dart';
import '../protocol/topics.dart';
import '../transport/transport.dart';

/// Pairing a new device with an existing identity: the same user on their
/// phone and on the website, without accounts or a server.
///
/// 1. The **new device** creates a [LinkRequest] (an ephemeral X25519 key pair
///    and a random link id), shows its [LinkRequest.uri] as a QR code or text
///    together with its [LinkRequest.code], and waits ([LinkRequest.receive]).
/// 2. The **existing device** parses the uri, shows the same code for the user
///    to compare, and sends the identity plus opaque app data (projects, name…)
///    with [LinkRequest.send]: sealed to the ephemeral key, so only the new
///    device can open it — and, with a password (second factor), also
///    encrypted with Argon2id(password), so that a QR code shown by someone
///    else is useless to them.
/// 3. The new device opens the transfer ([LinkTransfer.open]) and clears it.
///
/// The transfer travels on `<base>/link/<link id>` as a retained message (the
/// new device may connect after it was sent) that expires after [expiry].
/// Format: `"PEPL1" | crypto_box_seal(ephemeral pk, flags u8 | body)`, flags
/// bit0 = password; body = `seed[32] | data`, or with a password
/// `ops u8 | mem u32 | salt[16] | nonce[24] | XChaCha20-Poly1305(Argon2id(password),
/// ad = "peplink1" | link id, seed[32] | data)`.
class LinkRequest {
  LinkRequest._(this.linkId, this.publicKey, this.broker, this.topicBase, this._keyPair);

  /// On the new device: a fresh request (keep it until the transfer arrived).
  factory LinkRequest.create(PepCrypto c, {String? broker, String topicBase = ChannelTopics.defaultBase}) {
    final kp = c.sodium.crypto.box.keyPair();
    return LinkRequest._(c.randomBytes(16), kp.publicKey, broker, topicBase, kp);
  }

  /// On the existing device: the request shown by the new one.
  factory LinkRequest.parse(String uri) {
    final Uri u;
    try {
      u = Uri.parse(uri.trim());
    } on FormatException {
      throw const FormatPepException('not a device link');
    }
    if ('${u.scheme}://${u.host}' != prefix) throw const FormatPepException('not a device link');
    final Map<String, String> q;
    try {
      q = Uri.splitQueryString(u.fragment);
    } on FormatException {
      throw const FormatPepException('malformed device link');
    }
    final id = q['l'] == null ? null : _tryB64(q['l']!);
    final pk = q['k'] == null ? null : _tryB64(q['k']!);
    if (id == null || id.length != 16 || pk == null || pk.length != 32) {
      throw const FormatPepException('malformed device link');
    }
    return LinkRequest._(id, pk, q['b'], q['t'] ?? ChannelTopics.defaultBase, null);
  }

  static const prefix = 'parcoursetpistes://link';
  static const _magic = 'PEPL1';
  static const expiry = Duration(minutes: 15);

  final Uint8List linkId;

  /// The new device's ephemeral X25519 public key.
  final Uint8List publicKey;

  /// Broker both devices meet on (null: the app's default).
  final String? broker;
  final String topicBase;
  final KeyPair? _keyPair;

  String get uri {
    final q = {
      'l': b64u(linkId),
      'k': b64u(publicKey),
      'b': ?broker,
      if (topicBase != ChannelTopics.defaultBase) 't': topicBase,
    };
    return '$prefix#${q.entries.map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}').join('&')}';
  }

  String get topic => '$topicBase/link/${b64u(linkId)}';

  /// Six digits both devices show, for the user to check they are pairing the
  /// device they think they are (e.g. `482 917`).
  String get code {
    final d = hash.sha256.convert([...utf8Bytes('peplink-code'), ...linkId, ...publicKey]).bytes;
    final n = ((d[0] << 24 | d[1] << 16 | d[2] << 8 | d[3]) & 0x7fffffff) % 1000000;
    final s = n.toString().padLeft(6, '0');
    return '${s.substring(0, 3)} ${s.substring(3)}';
  }

  /// Existing device: sends [identity] (and [data]) to the requesting device.
  Future<void> send(
    PepCrypto c,
    Transport transport,
    Identity identity, {
    String? password,
    Uint8List? data,
    KdfParams? kdf,
  }) async {
    final plain = Uint8List.fromList([...identity.exportSeed(), ...?data]);
    final Uint8List inner;
    if (password == null) {
      inner = Uint8List.fromList([0, ...plain]);
    } else {
      final p = kdf ?? KdfParams.generate(c);
      final key = _passwordKey(c, password, p);
      try {
        final nonce = c.randomBytes(24);
        final ct = c.sodium.crypto.aeadXChaCha20Poly1305IETF.encrypt(
          message: plain,
          nonce: nonce,
          key: key,
          additionalData: _ad,
        );
        inner =
            (ByteWriter()
                  ..u8(1)
                  ..u8(p.opsLimit)
                  ..u32(p.memLimit)
                  ..bytes(p.salt)
                  ..bytes(nonce)
                  ..bytes(ct))
                .take();
      } finally {
        key.dispose();
      }
    }
    final sealed = c.sodium.crypto.box.seal(message: inner, publicKey: publicKey);
    if (transport.state != TransportState.connected) await transport.connect();
    await transport.publish(topic, Uint8List.fromList([...utf8Bytes(_magic), ...sealed]), retain: true, expiry: expiry);
  }

  /// New device: waits for the transfer (then clears it from the broker).
  /// Throws [TimeoutException] after [timeout].
  Future<LinkTransfer> receive(PepCrypto c, Transport transport, {Duration timeout = expiry}) async {
    final kp = _keyPair;
    if (kp == null) throw StateError('only the device that created the request can receive');
    if (transport.state != TransportState.connected) await transport.connect();
    final got = Completer<LinkTransfer>();
    final sub = transport.messages.listen((m) {
      if (m.topic != topic || m.payload.isEmpty || got.isCompleted) return;
      final inner = _open(c, kp, m.payload);
      if (inner != null) got.complete(LinkTransfer._(inner, linkId));
    });
    try {
      await transport.subscribe(topic);
      final t = await got.future.timeout(timeout);
      await transport.publish(topic, Uint8List(0), retain: true);
      return t;
    } finally {
      await sub.cancel();
      await transport.unsubscribe(topic);
    }
  }

  /// Forgets the ephemeral secret key.
  void dispose() => _keyPair?.secretKey.dispose();

  Uint8List get _ad => _associatedData(linkId);

  static Uint8List _associatedData(Uint8List linkId) => Uint8List.fromList([...utf8Bytes('peplink1'), ...linkId]);

  static Uint8List? _open(PepCrypto c, KeyPair kp, Uint8List payload) {
    final magic = utf8Bytes(_magic);
    if (payload.length <= magic.length || !bytesEqual(payload.sublist(0, magic.length), magic)) return null;
    try {
      return c.sodium.crypto.box.sealOpen(
        cipherText: payload.sublist(magic.length),
        publicKey: kp.publicKey,
        secretKey: kp.secretKey,
      );
    } catch (_) {
      return null; // not for us, or tampered with
    }
  }

  static Uint8List? _tryB64(String s) {
    try {
      return unb64u(s);
    } on FormatException {
      return null;
    } on PepException {
      return null;
    }
  }
}

/// A received device link; [open] it (with the password if [needsPassword]).
class LinkTransfer {
  LinkTransfer._(this._inner, this._linkId);

  final Uint8List _inner;
  final Uint8List _linkId;

  /// The sender protected the transfer with a password (second factor).
  bool get needsPassword => _inner.isNotEmpty && _inner[0] == 1;

  /// The identity and the app data. Throws [WrongPasswordException] (wrong or
  /// missing password) or [FormatPepException].
  ({Identity identity, Uint8List data}) open(PepCrypto c, {String? password}) {
    if (_inner.isEmpty) throw const FormatPepException('empty device link');
    Uint8List plain;
    if (!needsPassword) {
      plain = Uint8List.sublistView(_inner, 1);
    } else {
      if (password == null || password.isEmpty) throw const WrongPasswordException();
      final r = ByteReader(Uint8List.sublistView(_inner, 1));
      final p = KdfParams(opsLimit: r.u8(), memLimit: r.u32(), salt: Uint8List.fromList(r.bytes(KdfParams.saltBytes)));
      final nonce = r.bytes(24);
      final ct = r.rest();
      final key = _passwordKey(c, password, p);
      try {
        plain = c.sodium.crypto.aeadXChaCha20Poly1305IETF.decrypt(
          cipherText: ct,
          nonce: nonce,
          key: key,
          additionalData: LinkRequest._associatedData(_linkId),
        );
      } catch (_) {
        throw const WrongPasswordException();
      } finally {
        key.dispose();
      }
    }
    if (plain.length < Identity.seedBytes) throw const FormatPepException('truncated device link');
    return (
      identity: Identity.fromSeed(c, Uint8List.fromList(plain.sublist(0, Identity.seedBytes))),
      data: Uint8List.fromList(plain.sublist(Identity.seedBytes)),
    );
  }
}

SecureKey _passwordKey(PepCrypto c, String password, KdfParams p) {
  if (password.isEmpty) throw const FormatPepException('empty password');
  return c.sodium.crypto.pwhash.callStr(
    outLen: 32,
    password: password,
    salt: p.salt,
    opsLimit: p.opsLimit,
    memLimit: p.memLimit,
    alg: CryptoPwhashAlgorithm.argon2id13,
  );
}
