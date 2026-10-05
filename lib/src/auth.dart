import 'dart:async';
import 'dart:convert';

import 'crypto.dart';
import 'errors.dart';
import 'http.dart';
import 'models.dart';

/// Where the signed-in session is kept between launches. In a Flutter app, back it with `flutter_secure_storage` (or
/// `shared_preferences`); the default keeps it in memory only.
abstract class SessionStorage {
  Future<String?> get(String key);
  Future<void> set(String key, String value);
  Future<void> remove(String key);
}

class MemorySessionStorage implements SessionStorage {
  final Map<String, String> _values = {};

  @override
  Future<String?> get(String key) async => _values[key];

  @override
  Future<void> set(String key, String value) async => _values[key] = value;

  @override
  Future<void> remove(String key) async => _values.remove(key);
}

/// Espobase App Authentication for your app's users (sign-up, sign-in, sessions). Access tokens are refreshed for you:
/// requests made through `from()`, `storage`, `functions` and `rpc` carry the signed-in user's token.
class AuthClient {
  AuthClient(
    this._http,
    this._storage, {
    required bool secretKey,
    required bool autoRefresh,
    required DateTime Function() now,
  })  : _secretKey = secretKey,
        _autoRefresh = autoRefresh,
        _now = now {
    mfa = MfaClient._(this, _http);
    final path = Uri.tryParse(_http.base)?.path ?? '';
    _storageKey =
        'espobase.auth.${path.replaceAll(RegExp(r'[^A-Za-z0-9_]+'), '_')}';
  }

  final Http _http;
  final SessionStorage _storage;
  final bool _secretKey;
  final bool _autoRefresh;
  final DateTime Function() _now;
  late final String _storageKey;

  Session? _session;
  bool _loaded = false;
  Future<Session>? _refreshing;
  String? _pendingMfa;
  final StreamController<AuthStateChange> _changes =
      StreamController<AuthStateChange>.broadcast();

  static const _refreshMarginSeconds = 30;

  /// Two-step sign-in: finish a waiting sign-in, set up and remove methods.
  late final MfaClient mfa;

  /// Sign-in, sign-out and refresh events.
  Stream<AuthStateChange> get onAuthStateChange => _changes.stream;

  void _guard() {
    if (_secretKey)
      throw EspobaseException.client(
          'secret_key', 'Use a publishable key for App Authentication.');
  }

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    final text = await _storage.get(_storageKey);
    if (text == null) return;
    try {
      _session = Session.fromJson(jsonDecode(text) as Map<String, dynamic>);
    } catch (_) {
      await _storage.remove(_storageKey); // unreadable: start signed out
    }
  }

  Future<void> _save(Session next, AuthEvent event) async {
    _session = next;
    _loaded = true;
    await _storage.set(_storageKey, jsonEncode(next.toJson()));
    _changes.add(AuthStateChange(event, next));
  }

  Future<void> _clear(AuthEvent event) async {
    _session = null;
    _loaded = true;
    await _storage.remove(_storageKey);
    _changes.add(AuthStateChange(event, null));
  }

  /// The current session (refreshed first when it is about to expire), or null when signed out.
  Future<Session?> currentSession() async {
    await _load();
    final current = _session;
    if (current == null) return null;
    if (_autoRefresh &&
        current.expiresAt - _refreshMarginSeconds <=
            _now().millisecondsSinceEpoch / 1000) {
      return refreshSession();
    }
    return current;
  }

  /// The signed-in user (from the stored session; null when signed out).
  Future<User?> currentUser() async => (await currentSession())?.user;

  /// Access token for API calls (null when signed out).
  Future<String?> accessToken() async => (await currentSession())?.accessToken;

  /// Turns a sign-in answer into a session, or throws `mfa_required` / `mfa_enrollment_required` when the second step is
  /// still waiting (then finish it with `auth.mfa.verify`).
  Future<Session> _finishSignIn(Map<String, dynamic> json, int status) async {
    if (json['mfa_required'] == true && json['mfa_token'] is String) {
      _pendingMfa = json['mfa_token'] as String;
      final enrollment = json['enrollment_required'] == true;
      throw EspobaseException(
        status: status,
        code: enrollment ? 'mfa_enrollment_required' : 'mfa_required',
        message: enrollment
            ? 'Set up two-step sign-in to finish signing in.'
            : 'Enter the code from your second sign-in step.',
        mfa: MfaPending(
          enrollmentRequired: enrollment,
          factors: [
            for (final f in (json['factors'] as List<dynamic>? ?? const []))
              MfaPendingFactor(
                (f as Map<String, dynamic>)['id'] as String,
                MfaFactorType.parse(f['type'] as String),
              ),
          ],
          recoveryCodes: json['recovery_codes'] == true,
        ),
      );
    }
    final session = Session.fromJson(json);
    _pendingMfa = null;
    await _save(session, AuthEvent.signedIn);
    return session;
  }

  Future<Session> _post(String path, Map<String, Object?> body) async {
    final result =
        await _http.send(path, method: 'POST', jsonBody: _compact(body));
    return _finishSignIn(result.json! as Map<String, dynamic>, result.status);
  }

  static Map<String, Object> _compact(Map<String, Object?> body) => {
        for (final e in body.entries)
          if (e.value != null) e.key: e.value!,
      };

  /// Creates an account. With email confirmation on (the default) the user gets a link and no session yet.
  /// [redirectTo] is where the link opens: an https URL or an app link such as `myapp://auth/callback`, listed under
  /// Authentication › Settings › Allowed redirect URLs.
  Future<SignUpResult> signUp(
      {required String email,
      required String password,
      String? redirectTo}) async {
    _guard();
    final result = await _http.send(
      '/auth/v1/signup',
      method: 'POST',
      jsonBody: _compact(
          {'email': email, 'password': password, 'redirect_to': redirectTo}),
    );
    final json = result.json! as Map<String, dynamic>;
    if (json['mfa_required'] == true)
      await _finishSignIn(json, result.status); // throws mfa_*
    final sessionJson = json['session'] as Map<String, dynamic>?;
    final session = sessionJson == null ? null : Session.fromJson(sessionJson);
    if (session != null) await _save(session, AuthEvent.signedIn);
    final userJson = json['user'] as Map<String, dynamic>?;
    return SignUpResult(
        user: userJson == null ? null : User.fromJson(userJson),
        session: session);
  }

  Future<Session> signInWithPassword(
      {required String email, required String password}) async {
    _guard();
    return _post('/auth/v1/token', {'email': email, 'password': password});
  }

  /// Native sign-in sheets: signs in with the identity token an app got from the provider (today: Sign in with Apple).
  /// Give the sheet `AppleNonce().hashed` and pass `AppleNonce().raw` here. The token's audience must be your app's
  /// bundle ID (add it under Authentication › Providers › Apple).
  Future<Session> signInWithIdToken({
    OAuthProvider provider = OAuthProvider.apple,
    required String token,
    required String nonce,
  }) async {
    _guard();
    return _post('/auth/v1/id-token',
        {'provider': provider.name, 'id_token': token, 'nonce': nonce});
  }

  /// Social sign-in with a web page (the provider must be on for the project). Open the returned URL in a web-auth
  /// session (for example `flutter_web_auth_2`) with your app's callback scheme; the user comes back to [redirectTo]
  /// with `?code=…` (or `?error=…`): pass that code to [exchangeCodeForSession]. The one-time secret stays on this
  /// device.
  Future<Uri> signInWithOAuth(
      {required OAuthProvider provider, String? redirectTo}) async {
    _guard();
    final pkce = Pkce.generate();
    await _storage.set('$_storageKey.code_verifier', pkce.verifier);
    return _http.uri('/auth/v1/authorize', {
      'provider': provider.name,
      'code_challenge': pkce.challenge,
      'code_challenge_method': 'S256',
      'apikey': _http.key,
      if (redirectTo != null) 'redirect_to': redirectTo,
    });
  }

  /// Finishes a social sign-in: the `code` from the redirect URL plus this device's PKCE verifier.
  Future<Session> exchangeCodeForSession(String code) async {
    _guard();
    final key = '$_storageKey.code_verifier';
    final verifier = await _storage.get(key);
    if (verifier == null) {
      throw EspobaseException.client('no_code_verifier',
          "This sign-in wasn't started on this device. Start it again.");
    }
    try {
      return await _post(
          '/auth/v1/exchange', {'auth_code': code, 'code_verifier': verifier});
    } finally {
      await _storage.remove(key); // one attempt per sign-in
    }
  }

  /// Confirms an email address with the token from the verification link, and signs the user in.
  Future<Session> verifyEmail({required String token}) =>
      _post('/auth/v1/verify', {'type': 'signup', 'token': token});

  /// Passwordless sign-in (turned on per project): emails a link and a 6-digit code.
  Future<void> signInWithOtp(
      {required String email,
      String? redirectTo,
      bool shouldCreateUser = true}) async {
    _guard();
    await _http.send(
      '/auth/v1/otp',
      method: 'POST',
      jsonBody: _compact({
        'email': email,
        'redirect_to': redirectTo,
        'create_user': shouldCreateUser
      }),
    );
  }

  /// Finishes a passwordless sign-in with the emailed code.
  Future<Session> verifyOtpCode(
          {required String email, required String code}) =>
      _post('/auth/v1/verify', {'type': 'email', 'email': email, 'code': code});

  /// Finishes a passwordless sign-in with the link's token.
  Future<Session> verifyOtpToken({required String token}) =>
      _post('/auth/v1/verify', {'type': 'magiclink', 'token': token});

  /// Ends the session on this device ([global]: on every device). The local session is cleared even when the network
  /// call fails.
  Future<void> signOut({bool global = false}) async {
    await _load();
    final token = _session?.accessToken;
    Object? failure;
    if (token != null) {
      try {
        await _http.send('/auth/v1/logout',
            method: 'POST',
            jsonBody: {'scope': global ? 'global' : 'local'},
            token: token);
      } catch (e) {
        failure = e;
      }
    }
    await _clear(AuthEvent.signedOut);
    if (failure != null &&
        !(failure is EspobaseException && failure.status == 401)) throw failure;
  }

  /// Swaps the refresh token for a new session. Concurrent callers share one request.
  Future<Session> refreshSession() {
    final running = _refreshing;
    if (running != null) return running;
    final future = _refresh();
    _refreshing = future;
    return future.whenComplete(() => _refreshing = null);
  }

  Future<Session> _refresh() async {
    await _load();
    final current = _session;
    if (current == null) throw EspobaseException.notSignedIn;
    try {
      final result = await _http.send('/auth/v1/refresh',
          method: 'POST', jsonBody: {'refresh_token': current.refreshToken});
      final next = Session.fromJson(result.json! as Map<String, dynamic>);
      await _save(next, AuthEvent.tokenRefreshed);
      return next;
    } on EspobaseException catch (e) {
      // The refresh token is spent or revoked: the user must sign in again.
      if (e.status == 400 || e.status == 401) await _clear(AuthEvent.signedOut);
      rethrow;
    }
  }

  Future<void> resetPasswordForEmail(String email, {String? redirectTo}) async {
    _guard();
    await _http.send('/auth/v1/recover',
        method: 'POST',
        jsonBody: _compact({'email': email, 'redirect_to': redirectTo}));
  }

  /// Completes a password reset with the token from the reset link.
  Future<void> resetPassword(
      {required String token, required String password}) async {
    await _http.send('/auth/v1/reset-password',
        method: 'POST', jsonBody: {'token': token, 'password': password});
  }

  /// Sets a new password and/or asks to change the email address (when the project allows it).
  Future<User> updateUser(
      {String? password,
      String? email,
      String? currentPassword,
      String? redirectTo}) async {
    final token = await accessToken();
    if (token == null) throw EspobaseException.notSignedIn;
    final json = await _http.jsonObject(
      '/auth/v1/user',
      method: 'PUT',
      token: token,
      body: _compact({
        'password': password,
        'email': email,
        'current_password': currentPassword,
        'redirect_to': redirectTo,
      }),
    );
    final user = User.fromJson(json['user'] as Map<String, dynamic>);
    final current = _session;
    if (current != null)
      await _save(current.withUser(user), AuthEvent.userUpdated);
    return user;
  }

  /// Confirms an email change with the token from the link sent to the new address.
  Future<User> verifyEmailChange({required String token}) async {
    final json = await _http.jsonObject('/auth/v1/verify',
        method: 'POST', body: {'type': 'email_change', 'token': token});
    final user = User.fromJson(json['user'] as Map<String, dynamic>);
    final current = _session;
    if (current != null && current.user.id == user.id)
      await _save(current.withUser(user), AuthEvent.userUpdated);
    return user;
  }

  /// Releases the event stream (when the client is no longer used).
  Future<void> dispose() => _changes.close();
}

/// Two-step sign-in (turned on per project). After `mfa_required`, [verify] finishes the sign-in with an authenticator
/// code, an emailed code ([challenge] sends it) or a recovery code.
class MfaClient {
  MfaClient._(this._auth, this._http);

  final AuthClient _auth;
  final Http _http;

  static final _noPending = EspobaseException.client('no_mfa_sign_in',
      'No sign-in is waiting for a second step. Sign in again.');

  /// Finishes the waiting sign-in.
  Future<Session> verify({required String code, String? factorId}) async {
    final mfaToken = _auth._pendingMfa;
    if (mfaToken == null) throw _noPending;
    try {
      final result = await _http.send('/auth/v1/mfa-verify',
          method: 'POST',
          jsonBody: AuthClient._compact(
              {'mfa_token': mfaToken, 'code': code, 'factor_id': factorId}));
      return await _auth._finishSignIn(
          result.json! as Map<String, dynamic>, result.status);
    } on EspobaseException catch (e) {
      if (e.code == 'invalid_mfa_token') _auth._pendingMfa = null;
      rethrow;
    }
  }

  Future<String?> _tokenUnlessWaiting() async {
    if (_auth._pendingMfa != null) return null;
    final token = await _auth.accessToken();
    if (token == null) throw EspobaseException.notSignedIn;
    return token;
  }

  /// Emails a code for the email method: for the waiting sign-in, or (signed in) before [unenroll].
  Future<void> challenge() async {
    final waiting = _auth._pendingMfa;
    final token = await _tokenUnlessWaiting();
    await _http.send('/auth/v1/mfa-challenge',
        method: 'POST',
        jsonBody: waiting == null ? <String, Object>{} : {'mfa_token': waiting},
        token: token);
  }

  /// Starts setting up a method. `totp` answers with `secret` and `uri` (show the URI as a QR code for authenticator
  /// apps); `email` sends a code to the user's address.
  Future<MfaEnrollment> enroll({required MfaFactorType type}) async {
    final waiting = _auth._pendingMfa;
    final token = await _tokenUnlessWaiting();
    final json = await _http.jsonObject('/auth/v1/mfa-enroll',
        method: 'POST',
        token: token,
        body: AuthClient._compact({'type': type.name, 'mfa_token': waiting}));
    return MfaEnrollment(
      factorId: json['factor_id'] as String,
      type: MfaFactorType.parse(json['type'] as String),
      secret: json['secret'] as String?,
      uri: json['uri'] as String?,
    );
  }

  /// Confirms a new method with its first code. The first method also returns recovery codes: show them once. During a
  /// waiting sign-in this signs the user in.
  Future<MfaEnrollmentResult> verifyEnrollment(
      {required String factorId, required String code}) async {
    final waiting = _auth._pendingMfa;
    final token = await _tokenUnlessWaiting();
    final result = await _http.send('/auth/v1/mfa-enroll-verify',
        method: 'POST',
        token: token,
        jsonBody: AuthClient._compact(
            {'factor_id': factorId, 'code': code, 'mfa_token': waiting}));
    final json = result.json! as Map<String, dynamic>;
    final sessionJson = json['session'] as Map<String, dynamic>?;
    Session? session;
    if (sessionJson != null)
      session = await _auth._finishSignIn(sessionJson, result.status);
    return MfaEnrollmentResult(
      recoveryCodes: (json['recovery_codes'] as List<dynamic>?)
          ?.map((c) => c as String)
          .toList(),
      session: session,
    );
  }

  /// The signed-in user's methods and how many recovery codes are left.
  Future<({List<MfaFactor> factors, int recoveryCodesLeft})>
      listFactors() async {
    final token = await _auth.accessToken();
    if (token == null) throw EspobaseException.notSignedIn;
    final json = await _http.jsonObject('/auth/v1/mfa-factors', token: token);
    return (
      factors: [
        for (final f in json['factors'] as List<dynamic>)
          MfaFactor.fromJson(f as Map<String, dynamic>)
      ],
      recoveryCodesLeft: json['recovery_codes_left'] as int,
    );
  }

  /// Removes a method; needs a current code (authenticator, emailed code or a recovery code).
  Future<void> unenroll(
      {required String factorId, required String code}) async {
    final token = await _auth.accessToken();
    if (token == null) throw EspobaseException.notSignedIn;
    await _http.send('/auth/v1/mfa-unenroll',
        method: 'POST',
        token: token,
        jsonBody: {'factor_id': factorId, 'code': code});
  }
}

class MfaEnrollment {
  const MfaEnrollment(
      {required this.factorId, required this.type, this.secret, this.uri});

  final String factorId;
  final MfaFactorType type;
  final String? secret;
  final String? uri;
}

class MfaEnrollmentResult {
  const MfaEnrollmentResult({this.recoveryCodes, this.session});

  final List<String>? recoveryCodes;
  final Session? session;
}
