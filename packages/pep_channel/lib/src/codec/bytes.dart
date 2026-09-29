import 'dart:convert';
import 'dart:typed_data';

import '../errors.dart';

/// Unpadded base64url, safe for MQTT topic levels and URL fragments.
String b64u(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

Uint8List unb64u(String s) {
  try {
    return base64Url.decode(base64Url.normalize(s));
  } on FormatException catch (e) {
    throw FormatPepException('invalid base64url: ${e.message}');
  }
}

Uint8List utf8Bytes(String s) => Uint8List.fromList(utf8.encode(s));

bool bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// Minimal big-endian byte writer.
class ByteWriter {
  final _b = BytesBuilder(copy: false);

  void u8(int v) => _b.addByte(v & 0xff);

  void u16(int v) {
    u8(v >> 8);
    u8(v);
  }

  void u32(int v) {
    if (v < 0 || v > 0xffffffff) throw ArgumentError.value(v, 'u32');
    u16(v ~/ 0x10000);
    u16(v % 0x10000);
  }

  void bytes(List<int> v) => _b.add(v);

  /// Length-prefixed (u16) byte string.
  void lp16(List<int> v) {
    if (v.length > 0xffff) throw ArgumentError('field too long');
    u16(v.length);
    bytes(v);
  }

  Uint8List take() => _b.takeBytes();
}

/// Minimal big-endian byte reader; throws [FormatPepException] on truncation.
class ByteReader {
  ByteReader(this._d);

  final Uint8List _d;
  int _p = 0;

  int get remaining => _d.length - _p;

  void _need(int n) {
    if (remaining < n) throw const FormatPepException('truncated data');
  }

  int u8() {
    _need(1);
    return _d[_p++];
  }

  int u16() => (u8() << 8) | u8();

  // Multiplication, not <<: bit shifts are 32-bit signed when compiled to JS.
  int u32() => u16() * 0x10000 + u16();

  Uint8List bytes(int n) {
    _need(n);
    final r = Uint8List.sublistView(_d, _p, _p + n);
    _p += n;
    return r;
  }

  Uint8List rest() => bytes(remaining);
}
