/// Malformed content: invalid GPX, JSON or out-of-range values.
class ContentFormatException implements Exception {
  const ContentFormatException(this.message);

  final String message;

  @override
  String toString() => 'ContentFormatException: $message';
}
