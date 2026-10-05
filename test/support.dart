import 'dart:convert';

import 'package:espobase/espobase.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const projectUrl = 'https://api.espobase.test/project/abcde12345';
final publishableKey = 'eb_pk_${'a' * 43}';
final secretKey = 'eb_sk_${'b' * 43}';

typedef Answer = http.Response Function(http.Request request);

/// A client whose requests are answered by [answer] and recorded in [requests].
class Harness {
  Harness(Answer answer,
      {ClientOptions Function(MockClient client)? options, String key = ''}) {
    final mock = MockClient((request) async {
      requests.add(request);
      return answer(request);
    });
    client = EspobaseClient(
      projectUrl,
      key.isEmpty ? publishableKey : key,
      options: options?.call(mock) ?? ClientOptions(httpClient: mock),
    );
  }

  final List<http.Request> requests = [];
  late final EspobaseClient client;
}

http.Response jsonResponse(Object body,
        [int status = 200, Map<String, String> headers = const {}]) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json', ...headers});

Map<String, dynamic> sessionJson(
        [int n = 1,
        int expiresIn = 900,
        DateTime? now,
        String userId = 'u1']) =>
    {
      'access_token': 'at$n',
      'refresh_token': 'rt$n',
      'token_type': 'bearer',
      'expires_in': expiresIn,
      'expires_at':
          ((now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000) + expiresIn,
      'user': {
        'id': userId,
        'email': 'a@b.co',
        'emailVerified': true,
        'appRole': 'authenticated',
        'provider': 'email',
        'providers': ['email'],
        'createdAt': '2026-10-01T00:00:00Z',
        'lastSignInAt': null,
      },
    };

Map<String, dynamic> bodyOf(http.Request r) =>
    jsonDecode(r.body) as Map<String, dynamic>;
