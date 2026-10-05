import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;

String base64UrlNoPad(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

Uint8List secureRandomBytes(int count) {
  final random = Random.secure();
  return Uint8List.fromList(
      List<int>.generate(count, (_) => random.nextInt(256)));
}

/// RFC 7636 (S256) verifier and challenge for a social sign-in.
class Pkce {
  Pkce._(this.verifier, this.challenge);

  final String verifier;
  final String challenge;

  factory Pkce.generate() {
    final verifier = base64UrlNoPad(secureRandomBytes(32));
    return Pkce._(verifier, pkceChallenge(verifier));
  }
}

String pkceChallenge(String verifier) =>
    base64UrlNoPad(c.sha256.convert(utf8.encode(verifier)).bytes);

/// Sign in with Apple: the nonce for the sign-in sheet. Give the sheet [hashed] and keep [raw] to send to
/// `auth.signInWithIdToken`.
class AppleNonce {
  AppleNonce() : this.fromRaw(base64UrlNoPad(secureRandomBytes(32)));

  AppleNonce.fromRaw(this.raw)
      : hashed = c.sha256.convert(utf8.encode(raw)).toString();

  final String raw;

  /// SHA-256 of [raw], lowercase hex (what Apple puts in the identity token).
  final String hashed;
}
