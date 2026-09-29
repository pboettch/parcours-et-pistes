import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../errors.dart';
import 'bytes.dart';

/// Upper bound for any decompressed payload (protects against deflate bombs).
const maxDecompressedSize = 64 * 1024 * 1024;

/// Compresses [data] as `u32 original length | raw deflate`.
///
/// The length prefix lets [inflate] detect corrupt streams (the deflate decoder
/// does not report them) and bounds memory before decoding.
Uint8List deflate(Uint8List data) {
  if (data.length > maxDecompressedSize) {
    throw ArgumentError('data exceeds $maxDecompressedSize bytes');
  }
  return (ByteWriter()
        ..u32(data.length)
        ..bytes(Deflate(data, level: DeflateLevel.bestCompression).getBytes()))
      .take();
}

Uint8List inflate(Uint8List data, {int maxSize = maxDecompressedSize}) {
  final r = ByteReader(data);
  final size = r.u32();
  if (size > maxSize) throw FormatPepException('decompressed data exceeds $maxSize bytes');
  final out = _LimitedOutput(size);
  try {
    Inflate(r.rest(), output: out);
  } on PepException {
    rethrow;
  } catch (e) {
    throw FormatPepException('corrupt compressed data: $e');
  }
  if (out.length != size) throw const FormatPepException('corrupt compressed data');
  return Uint8List.fromList(out.getBytes());
}

class _LimitedOutput extends OutputMemoryStream {
  _LimitedOutput(this.maxSize) : super(size: maxSize == 0 ? 1 : maxSize);

  final int maxSize;

  void _check(int add) {
    if (length + add > maxSize) {
      throw FormatPepException('decompressed data exceeds $maxSize bytes');
    }
  }

  @override
  void writeByte(int value) {
    _check(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _check(length ?? bytes.length);
    super.writeBytes(bytes, length: length);
  }

  @override
  void writeStream(InputStream stream) {
    _check(stream.length);
    super.writeStream(stream);
  }

  @override
  void writeBackReference(int distance, int count) {
    _check(count);
    super.writeBackReference(distance, count);
  }
}
