import 'dart:convert';
import 'dart:typed_data';

import 'auth.dart';
import 'errors.dart';
import 'http.dart';

/// A function's answer. [data] is the parsed JSON for `application/json`, a `String` for `text/*`, otherwise `Uint8List`.
class FunctionResponse {
  FunctionResponse(this.data, this.status, this.contentType);

  final Object? data;
  final int status;
  final String? contentType;
}

/// Edge functions: calls carry the project key and, when a user is signed in, their access token, so the function
/// receives the verified user (`x-espobase-user-id`, `x-espobase-user-email`, `x-espobase-user-role`).
class FunctionsClient {
  FunctionsClient(this._http, this._auth);

  final Http _http;
  final AuthClient _auth;

  /// Calls the function [name]. A `Map` or `List` [body] is sent as JSON; a `String` as text; `Uint8List` as bytes.
  /// Error statuses throw an [EspobaseException] (the function's own JSON `{ error, message }` is used when present).
  Future<FunctionResponse> invoke(
    String name, {
    String method = 'POST',
    Object? body,
    Map<String, String> headers = const {},
    Map<String, String> query = const {},
  }) async {
    if (!RegExp(r'^[a-z0-9][a-z0-9-]{0,62}$').hasMatch(name)) {
      throw EspobaseException.client('invalid_function',
          'functions.invoke(): a function name (lowercase, digits, -) is required.');
    }
    final extra = {...headers};
    final hasContentType =
        extra.keys.any((k) => k.toLowerCase() == 'content-type');
    Object? json;
    List<int>? bytes;
    String? contentType;
    if (body is Uint8List) {
      bytes = body;
      contentType = 'application/octet-stream';
    } else if (body is String) {
      bytes = utf8.encode(body);
      contentType = 'text/plain;charset=utf-8';
    } else if (body != null) {
      json = body;
    }
    if (hasContentType) {
      contentType = extra.entries
          .firstWhere((e) => e.key.toLowerCase() == 'content-type')
          .value;
      extra.removeWhere((k, _) => k.toLowerCase() == 'content-type');
    }
    final result = await _http.send(
      '/functions/v1/$name',
      method: method,
      jsonBody: json,
      bytes: bytes,
      contentType: contentType,
      token: await _auth.accessToken(),
      query: query.isEmpty ? null : query,
      extraHeaders: extra,
    );
    final type = result.headers['content-type'];
    final Object? data;
    if (type != null &&
        RegExp(r'\bjson\b', caseSensitive: false).hasMatch(type)) {
      data = result.json;
    } else if (type != null &&
        RegExp(r'^text/', caseSensitive: false).hasMatch(type)) {
      data = result.text;
    } else {
      data = result.bodyBytes;
    }
    return FunctionResponse(data, result.status, type);
  }
}
