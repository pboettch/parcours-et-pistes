/// Base class of the protocol errors of pep_channel (also raised through
/// pep_core). Transport failures are `TransportException`s; misuse, such as
/// writing to a closed channel, raises a `StateError`.
class PepException implements Exception {
  const PepException(this.message);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// Malformed input: bad encoding, unknown version, out-of-range parameters.
class FormatPepException extends PepException {
  const FormatPepException(super.message);
}

/// Decryption failed: wrong password/key, tampered data or wrong topic.
class DecryptionException extends PepException {
  const DecryptionException(super.message);
}

/// A signature is invalid, or the signer is not allowed to publish this content.
class AuthorizationException extends PepException {
  const AuthorizationException(super.message);
}

/// The password does not match the project.
class WrongPasswordException extends PepException {
  const WrongPasswordException() : super('wrong password');
}

/// No channel (metadata or access list signed by the expected owner) was found
/// for the given id on the broker.
class ChannelNotFoundException extends PepException {
  const ChannelNotFoundException(super.message);
}
