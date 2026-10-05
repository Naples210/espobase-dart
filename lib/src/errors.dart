/// An error from Espobase or the network. [status] is the HTTP status (0 for network and client-side errors) and
/// [code] is an Espobase or PostgreSQL error code such as `invalid_credentials` or `42501`.
class EspobaseException implements Exception {
  EspobaseException({
    required this.status,
    required this.code,
    required this.message,
    this.details,
    this.hint,
    this.mfa,
  });

  final int status;
  final String code;
  final String message;
  final String? details;
  final String? hint;

  /// With `mfa_required` / `mfa_enrollment_required`: the sign-in waits for its second step (`auth.mfa.verify`).
  final MfaPending? mfa;

  /// An error raised by the client itself (no request was made, or the answer was unusable).
  factory EspobaseException.client(String code, String message) =>
      EspobaseException(status: 0, code: code, message: message);

  static final notSignedIn = EspobaseException(
      status: 401, code: 'no_session', message: 'Not signed in.');

  @override
  String toString() => 'EspobaseException($status $code: $message)';
}

/// A sign-in that waits for its second step.
class MfaPending {
  const MfaPending(
      {required this.enrollmentRequired,
      required this.factors,
      required this.recoveryCodes});

  final bool enrollmentRequired;
  final List<MfaPendingFactor> factors;

  /// Whether a recovery code can be used instead.
  final bool recoveryCodes;
}

class MfaPendingFactor {
  const MfaPendingFactor(this.id, this.type);

  final String id;
  final MfaFactorType type;

  @override
  bool operator ==(Object other) =>
      other is MfaPendingFactor && other.id == id && other.type == type;

  @override
  int get hashCode => Object.hash(id, type);
}

enum MfaFactorType {
  totp,
  email;

  static MfaFactorType parse(String value) =>
      MfaFactorType.values.firstWhere((t) => t.name == value);
}
