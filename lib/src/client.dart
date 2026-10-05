import 'package:http/http.dart' as http;

import 'auth.dart';
import 'errors.dart';
import 'functions.dart';
import 'http.dart';
import 'query.dart';
import 'storage.dart';

/// Options for [EspobaseClient]. Every field has a default.
class ClientOptions {
  const ClientOptions({
    this.sessionStorage,
    this.autoRefreshToken = true,
    this.headers = const {},
    this.httpClient,
    this.serverSide = false,
    this.now,
  });

  /// Where the session is kept. Default: memory (use `flutter_secure_storage` in an app to stay signed in).
  final SessionStorage? sessionStorage;

  /// Refresh the access token shortly before it expires (default: true).
  final bool autoRefreshToken;

  /// Extra headers on every request (never put keys here).
  final Map<String, String> headers;

  /// Another HTTP client (default: a new `http.Client`).
  final http.Client? httpClient;

  /// Allow a secret key (`eb_sk_…`): only for trusted servers, never in an app.
  final bool serverSide;

  /// The clock (tests).
  final DateTime Function()? now;
}

/// The Espobase client: your project's database ([from], [rpc]), App Authentication ([auth]), Storage ([storage]) and
/// edge functions ([functions]).
///
/// ```dart
/// final client = EspobaseClient('https://api.espobase.com/project/<ref>', 'eb_pk_…');
/// ```
class EspobaseClient {
  factory EspobaseClient(String url, String key,
      {ClientOptions options = const ClientOptions()}) {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !(uri.scheme == 'https' || uri.scheme == 'http') ||
        uri.host.isEmpty) {
      throw EspobaseException.client(
          'invalid_url', 'The project URL must be an absolute http(s) URL.');
    }
    if (!RegExp(r'^eb_(pk|sk)_[0-9A-Za-z]{43}$').hasMatch(key)) {
      throw EspobaseException.client('invalid_key',
          "That doesn't look like an Espobase API key (eb_pk_… or eb_sk_…).");
    }
    final secret = key.startsWith('eb_sk_');
    if (secret && !options.serverSide) {
      throw EspobaseException.client('secret_key',
          'Espobase secret keys bypass row level security and must never be used in an app. Use the publishable key.');
    }
    var base = uri.replace(query: '', fragment: '').toString();
    base =
        base.replaceAll(RegExp(r'[?#]+$'), '').replaceAll(RegExp(r'/+$'), '');
    if (base.endsWith('/rest/v1'))
      base = base.substring(0, base.length - '/rest/v1'.length);
    final client =
        Http(base, key, options.httpClient ?? http.Client(), options.headers);
    final auth = AuthClient(
      client,
      options.sessionStorage ?? MemorySessionStorage(),
      secretKey: secret,
      autoRefresh: options.autoRefreshToken,
      now: options.now ?? DateTime.now,
    );
    return EspobaseClient._(client, auth);
  }

  EspobaseClient._(this._http, this.auth)
      : storage = StorageClient(_http, auth),
        functions = FunctionsClient(_http, auth);

  final Http _http;
  final AuthClient auth;
  final StorageClient storage;
  final FunctionsClient functions;

  /// A query on a table or view.
  QueryBuilder from(String table) {
    if (table.isEmpty)
      throw EspobaseException.client(
          'invalid_table', 'from(): a table name is required.');
    return QueryBuilder(_http, auth, table);
  }

  /// Calls a database function in your project (`POST /rest/v1/rpc/<fn>`), as the signed-in user, so row level security
  /// applies. Returns the decoded JSON.
  Future<Object?> rpc(String function,
      {Map<String, Object?> params = const {}}) async {
    if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,62}$').hasMatch(function)) {
      throw EspobaseException.client(
          'invalid_function', 'rpc(): a function name is required.');
    }
    final result = await _http.send('/rest/v1/rpc/$function',
        method: 'POST', jsonBody: params, token: await auth.accessToken());
    return result.json;
  }

  /// Releases resources (the HTTP client and the auth event stream).
  Future<void> close() async {
    _http.client.close();
    await auth.dispose();
  }
}
