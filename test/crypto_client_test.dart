import 'package:espobase/espobase.dart';
import 'package:espobase/src/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('crypto', () {
    test('PKCE challenge is the S256 of the verifier (RFC 7636 appendix B)',
        () {
      expect(pkceChallenge('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'),
          'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM');
      final pkce = Pkce.generate();
      expect(pkce.verifier.length, 43);
      expect(Pkce.generate().verifier, isNot(pkce.verifier));
      expect(pkce.challenge, pkceChallenge(pkce.verifier));
    });

    test('Apple nonce: the hash is lowercase hex of the raw value', () {
      expect(AppleNonce.fromRaw('abc').hashed,
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
      final n = AppleNonce();
      expect(n.raw.length, greaterThanOrEqualTo(32));
      expect(n.hashed.length, 64);
      expect(AppleNonce().raw, isNot(n.raw));
    });
  });

  group('client', () {
    test('refuses bad URLs, bad keys and secret keys in an app', () {
      expect(() => EspobaseClient('ftp://x.test', publishableKey),
          throwsA(_code('invalid_url')));
      expect(() => EspobaseClient(projectUrl, 'nope'),
          throwsA(_code('invalid_key')));
      expect(() => EspobaseClient(projectUrl, secretKey),
          throwsA(_code('secret_key')));
      expect(
          () => EspobaseClient(projectUrl, secretKey,
              options: const ClientOptions(serverSide: true)),
          returnsNormally);
    });

    test(
        'accepts a URL ending in /rest/v1 or a slash, sends the key and client info, normalizes errors',
        () async {
      for (final text in [
        '$projectUrl/rest/v1/',
        '$projectUrl/',
        '$projectUrl?x=1'
      ]) {
        final seen = <http.Request>[];
        final mock = MockClient((r) async {
          seen.add(r);
          return jsonResponse([]);
        });
        final c = EspobaseClient(text, publishableKey,
            options:
                ClientOptions(httpClient: mock, headers: {'x-extra': '1'}));
        await c.from('t');
        expect(seen.single.url.toString(), '$projectUrl/rest/v1/t');
        expect(seen.single.headers['apikey'], publishableKey);
        expect(
            seen.single.headers['x-client-info'], startsWith('espobase-dart/'));
        expect(seen.single.headers['x-extra'], '1');
        expect(seen.single.headers.containsKey('authorization'), isFalse);
      }
      final h = Harness((r) => jsonResponse(
          {'code': 'PGRST205', 'message': 'no table', 'hint': 'check'}, 404));
      await expectLater(
        h.client.from('missing'),
        throwsA(isA<EspobaseException>()
            .having((e) => e.status, 'status', 404)
            .having((e) => e.code, 'code', 'PGRST205')
            .having((e) => e.hint, 'hint', 'check')),
      );
    });

    test('network failures become errors', () async {
      final c = EspobaseClient(projectUrl, publishableKey,
          options: ClientOptions(
              httpClient: MockClient(
                  (_) async => throw http.ClientException('offline'))));
      await expectLater(c.from('t'), throwsA(_code('network_error')));
    });

    test(
        'rpc sends the arguments with the signed-in user token and validates the name',
        () async {
      final h = Harness((r) => r.url.path.endsWith('/auth/v1/token')
          ? jsonResponse(sessionJson())
          : jsonResponse([
              {'id': 7}
            ]));
      await h.client.auth.signInWithPassword(email: 'a@b.co', password: 'pw');
      final rows =
          await h.client.rpc('match_documents', params: {'match_count': 5});
      expect(rows, [
        {'id': 7}
      ]);
      final call = h.requests.last;
      expect(call.url.path, '/project/abcde12345/rest/v1/rpc/match_documents');
      expect(call.headers['authorization'], 'Bearer at1');
      expect(bodyOf(call)['match_count'], 5);
      await expectLater(
          h.client.rpc('bad name!'), throwsA(_code('invalid_function')));
    });
  });
}

Matcher _code(String code) =>
    isA<EspobaseException>().having((e) => e.code, 'code', code);
