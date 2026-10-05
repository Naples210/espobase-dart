import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'errors.dart';

const sdkVersion = '0.1.0';

/// The answer to a request.
class HttpResult {
  HttpResult(this.status, this.bodyBytes, this.headers);

  final int status;
  final Uint8List bodyBytes;
  final Map<String, String> headers;

  String get text => utf8.decode(bodyBytes, allowMalformed: true);

  /// The JSON body (null when empty).
  Object? get json => bodyBytes.isEmpty ? null : jsonDecode(text);
}

/// Low-level HTTP: adds the API key, the user's token when given, JSON bodies and normalized errors.
class Http {
  Http(this.base, this.key, this.client, this.headers);

  final String base;
  final String key;
  final http.Client client;
  final Map<String, String> headers;

  Uri uri(String path,
      [Map<String, String>? query, List<MapEntry<String, String>>? repeated]) {
    final parsed = Uri.parse('$base$path');
    final all = <String, List<String>>{
      for (final e in parsed.queryParametersAll.entries) e.key: e.value,
    };
    for (final e in (query ?? const <String, String>{}).entries) {
      all.putIfAbsent(e.key, () => []).add(e.value);
    }
    for (final e in repeated ?? const <MapEntry<String, String>>[]) {
      all.putIfAbsent(e.key, () => []).add(e.value);
    }
    return parsed.replace(queryParameters: all.isEmpty ? null : all);
  }

  /// Sends a request. Non-2xx answers throw an [EspobaseException] (Espobase's `{error, message}` or PostgREST's
  /// `{code, message, details, hint}`).
  Future<HttpResult> send(
    String path, {
    String method = 'GET',
    Object? jsonBody,
    List<int>? bytes,
    String? contentType,
    String? token,
    Map<String, String>? query,
    List<MapEntry<String, String>>? repeatedQuery,
    Map<String, String> extraHeaders = const {},
  }) async {
    final request = http.Request(method, uri(path, query, repeatedQuery));
    request.headers.addAll({
      'x-client-info': 'espobase-dart/$sdkVersion',
      ...headers,
      ...extraHeaders,
      'apikey': key
    });
    if (token != null) request.headers['authorization'] = 'Bearer $token';
    if (jsonBody != null) {
      request.headers['content-type'] = 'application/json';
      request.body = jsonEncode(jsonBody);
    } else if (bytes != null) {
      request.headers['content-type'] =
          contentType ?? 'application/octet-stream';
      request.bodyBytes = bytes;
    }
    final http.Response response;
    try {
      response = await http.Response.fromStream(await client.send(request));
    } on EspobaseException {
      rethrow;
    } catch (e) {
      throw EspobaseException(status: 0, code: 'network_error', message: '$e');
    }
    final result =
        HttpResult(response.statusCode, response.bodyBytes, response.headers);
    if (response.statusCode < 200 || response.statusCode >= 300)
      throw errorFrom(result);
    return result;
  }

  static EspobaseException errorFrom(HttpResult result) {
    Map<String, dynamic>? body;
    try {
      final decoded = result.json;
      if (decoded is Map<String, dynamic>) body = decoded;
    } catch (_) {
      body = null;
    }
    return EspobaseException(
      status: result.status,
      code: (body?['error'] as String?) ??
          (body?['code'] as String?) ??
          'http_error',
      message:
          (body?['message'] as String?) ?? 'Request failed (${result.status})',
      details: body?['details'] as String?,
      hint: body?['hint'] as String?,
    );
  }

  /// A request whose answer is a JSON object.
  Future<Map<String, dynamic>> jsonObject(
    String path, {
    String method = 'GET',
    Object? body,
    String? token,
    Map<String, String>? query,
  }) async {
    final result = await send(path,
        method: method, jsonBody: body, token: token, query: query);
    final decoded = result.json;
    if (decoded is Map<String, dynamic>) return decoded;
    throw EspobaseException.client(
        'decode_error', 'The answer was not a JSON object.');
  }
}
