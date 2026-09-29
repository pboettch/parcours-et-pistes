import 'dart:convert';
import 'dart:typed_data';

import 'errors.dart';

typedef Json = Map<String, dynamic>;

Uint8List utf8Bytes(String s) => Uint8List.fromList(utf8.encode(s));

Uint8List encodeJson(Json j) => Uint8List.fromList(utf8.encode(jsonEncode(j)));

Json decodeJson(Uint8List bytes) {
  try {
    final v = jsonDecode(utf8.decode(bytes));
    if (v is Json) return v;
  } on FormatException {
    // fall through
  }
  throw const ContentFormatException('payload is not a JSON object');
}

/// Typed field access raising [ContentFormatException] instead of TypeErrors.
extension JsonGet on Json {
  T req<T>(String k) {
    final v = this[k];
    if (v is T) return v;
    throw ContentFormatException('field "$k" missing or not ${T.toString()}');
  }

  T? opt<T>(String k) {
    final v = this[k];
    if (v == null || v is T) return v as T?;
    throw ContentFormatException('field "$k" is not ${T.toString()}');
  }

  double reqNum(String k) => req<num>(k).toDouble();

  double? optNum(String k) => opt<num>(k)?.toDouble();

  Json optMap(String k) => opt<Map<String, dynamic>>(k) ?? <String, dynamic>{};

  List<String> strList(String k) {
    final v = opt<List<dynamic>>(k) ?? const [];
    return [
      for (final e in v) e is String ? e : throw ContentFormatException('field "$k" must hold strings')
    ];
  }

  /// Format version check: accepts [supported] and rejects anything newer.
  void checkVersion(int supported) {
    final v = req<int>('v');
    if (v < 1 || v > supported) throw ContentFormatException('unsupported document version $v');
  }
}

DateTime msToDate(int ms) => DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
