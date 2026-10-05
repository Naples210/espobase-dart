import 'dart:async';

import 'package:espobase/espobase.dart';
import 'package:espobase/src/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import 'support.dart';

Matcher _code(String code) =>
    isA<EspobaseException>().having((e) => e.code, 'code', code);

void main() {
  test(
      'sign-in keeps the session, attaches the token to later calls and emits events',
      () async {
    final h = Harness((r) => r.url.path.endsWith('/auth/v1/token')
        ? jsonResponse(sessionJson())
        : jsonResponse([]));
    final events = <AuthEvent>[];
    final sub =
        h.client.auth.onAuthStateChange.listen((c) => events.add(c.event));
    final session = await h.client.auth
        .signInWithPassword(email: 'a@b.co', password: 'pw-123456');
    expect(session.accessToken, 'at1');
    expect(session.user.email, 'a@b.co');
    expect(
        bodyOf(h.requests.first), {'email': 'a@b.co', 'password': 'pw-123456'});
    await h.client.from('orders');
    expect(h.requests.last.headers['authorization'], 'Bearer at1');
    expect((await h.client.auth.currentUser())?.id, 'u1');
    await h.client.auth.signOut();
    expect(h.requests.last.url.path, '/project/abcde12345/auth/v1/logout');
    expect(await h.client.auth.currentSession(), isNull);
    await Future<void>.delayed(Duration.zero);
    expect(events, [AuthEvent.signedIn, AuthEvent.signedOut]);
    await sub.cancel();
  });

  test('the session survives a restart through the storage', () async {
    final storage = MemorySessionStorage();
    Harness make() => Harness((r) => jsonResponse(sessionJson()),
        options: (mock) =>
            ClientOptions(httpClient: mock, sessionStorage: storage));
    await make()
        .client
        .auth
        .signInWithPassword(email: 'a@b.co', password: 'pw');
    expect((await make().client.auth.currentSession())?.accessToken, 'at1');
  });

  test('an expiring session is refreshed once, even for concurrent callers',
      () async {
    var now = DateTime.fromMillisecondsSinceEpoch(1800000000000);
    var refreshes = 0;
    final h = Harness(
      (r) {
        if (r.url.path.endsWith('/auth/v1/token'))
          return jsonResponse(sessionJson(1, 60, now));
        if (r.url.path.endsWith('/auth/v1/refresh')) {
          refreshes++;
          return jsonResponse(sessionJson(2, 900, now));
        }
        return jsonResponse([]);
      },
      options: (mock) => ClientOptions(httpClient: mock, now: () => now),
    );
    await h.client.auth.signInWithPassword(email: 'a@b.co', password: 'pw');
    now = now.add(
        const Duration(seconds: 40)); // inside the 30 s margin of a 60 s token
    final tokens = await Future.wait(
        [h.client.auth.accessToken(), h.client.auth.accessToken()]);
    expect(tokens, ['at2', 'at2']);
    expect(refreshes, 1);
    expect(
        bodyOf(h.requests.firstWhere((r) => r.url.path.endsWith('/refresh')))[
            'refresh_token'],
        'rt1');
  });

  test('a revoked refresh token signs the user out', () async {
    var now = DateTime.fromMillisecondsSinceEpoch(1800000000000);
    final h = Harness(
      (r) => r.url.path.endsWith('/auth/v1/token')
          ? jsonResponse(sessionJson(1, 60, now))
          : jsonResponse(
              {'error': 'invalid_grant', 'message': 'Invalid refresh token.'},
              401),
      options: (mock) => ClientOptions(httpClient: mock, now: () => now),
    );
    await h.client.auth.signInWithPassword(email: 'a@b.co', password: 'pw');
    now = now.add(const Duration(seconds: 45));
    await expectLater(
        h.client.auth.accessToken(), throwsA(_code('invalid_grant')));
    expect(await h.client.auth.currentSession(), isNull);
  });

  test('sign-up with confirmation returns no session and passes the app link',
      () async {
    final h = Harness(
        (r) => jsonResponse({'user': sessionJson()['user'], 'session': null}));
    final result = await h.client.auth.signUp(
        email: 'a@b.co',
        password: 'pw-123456',
        redirectTo: 'myapp://auth/callback');
    expect(result.user, isNotNull);
    expect(result.session, isNull);
    expect(bodyOf(h.requests.single)['redirect_to'], 'myapp://auth/callback');
    expect(await h.client.auth.currentSession(), isNull);
  });

  test('Sign in with Apple sends the identity token and the RAW nonce',
      () async {
    final h = Harness((r) => jsonResponse(sessionJson(3)));
    final nonce = AppleNonce();
    final session = await h.client.auth
        .signInWithIdToken(token: 'x' * 40, nonce: nonce.raw);
    expect(session.accessToken, 'at3');
    expect(h.requests.single.url.path, '/project/abcde12345/auth/v1/id-token');
    final body = bodyOf(h.requests.single);
    expect(body['provider'], 'apple');
    expect(body['nonce'], nonce.raw);
    expect(body['nonce'], isNot(nonce.hashed),
        reason: 'the raw nonce goes to Espobase, the hash to Apple');
    expect(body['id_token'], 'x' * 40);
  });

  test(
      'social sign-in builds the authorize URL and exchanges the code with this device\'s verifier, once',
      () async {
    final h = Harness((r) => jsonResponse(sessionJson(4)));
    final url = await h.client.auth.signInWithOAuth(
        provider: OAuthProvider.google, redirectTo: 'myapp://auth/callback');
    expect(url.path, '/project/abcde12345/auth/v1/authorize');
    final q = url.queryParameters;
    expect(q['provider'], 'google');
    expect(q['code_challenge_method'], 'S256');
    expect(q['apikey'], publishableKey);
    expect(q['redirect_to'], 'myapp://auth/callback');
    await h.client.auth.exchangeCodeForSession('one-time-code');
    final verifier = bodyOf(h.requests.single)['code_verifier'] as String;
    expect(pkceChallenge(verifier), q['code_challenge']);
    await expectLater(h.client.auth.exchangeCodeForSession('again'),
        throwsA(_code('no_code_verifier')));
  });

  test(
      'two-step sign-in waits for the second step and finishes with the mfa token',
      () async {
    final h = Harness((r) => r.url.path.endsWith('/auth/v1/token')
        ? jsonResponse({
            'mfa_required': true,
            'enrollment_required': false,
            'mfa_token': 'mfa-token-1',
            'factors': [
              {'id': 'f1', 'type': 'totp'}
            ],
            'recovery_codes': true,
          })
        : jsonResponse(sessionJson(5)));
    await expectLater(
      h.client.auth.signInWithPassword(email: 'a@b.co', password: 'pw'),
      throwsA(isA<EspobaseException>()
          .having((e) => e.code, 'code', 'mfa_required')
          .having((e) => e.mfa?.factors, 'factors', [
        const MfaPendingFactor('f1', MfaFactorType.totp)
      ]).having((e) => e.mfa?.recoveryCodes, 'recovery', true)),
    );
    expect(await h.client.auth.currentSession(), isNull,
        reason: 'no session until the second step');
    final session = await h.client.auth.mfa.verify(code: '123456');
    expect(session.accessToken, 'at5');
    expect(bodyOf(h.requests.last)['mfa_token'], 'mfa-token-1');
    await expectLater(h.client.auth.mfa.verify(code: '123456'),
        throwsA(_code('no_mfa_sign_in')));
  });

  test('a publishable key is required for auth, and updateUser needs a session',
      () async {
    final seen = <http.Request>[];
    final server = EspobaseClient(projectUrl, secretKey,
        options: ClientOptions(
            serverSide: true,
            httpClient: MockClient((r) async {
              seen.add(r);
              return jsonResponse(sessionJson());
            })));
    await expectLater(
        server.auth.signInWithPassword(email: 'a@b.co', password: 'pw'),
        throwsA(_code('secret_key')));
    expect(seen, isEmpty);
    final h = Harness((r) => jsonResponse({'user': sessionJson()['user']}));
    await expectLater(h.client.auth.updateUser(password: 'new-password-1'),
        throwsA(_code('no_session')));
  });
}
