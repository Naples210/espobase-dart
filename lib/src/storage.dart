import 'dart:convert';
import 'dart:typed_data';

import 'auth.dart';
import 'errors.dart';
import 'http.dart';
import 'models.dart';

String _encodePath(String path) =>
    path.split('/').map(Uri.encodeComponent).join('/');

/// Espobase Storage. Requests carry the project key and, when a user is signed in, their access token, so the project's
/// storage policies decide what each user may do.
class StorageClient {
  StorageClient(this._http, this._auth);

  final Http _http;
  final AuthClient _auth;

  /// Files in one bucket (lowercase letters, digits, `-` and `_`).
  BucketClient from(String bucket) {
    if (!RegExp(r'^[a-z0-9][a-z0-9_-]{1,62}$').hasMatch(bucket)) {
      throw EspobaseException.client('invalid_bucket',
          'storage.from(): a bucket name (lowercase letters, digits, - and _) is required.');
    }
    return BucketClient(_http, _auth, bucket);
  }
}

class BucketClient {
  BucketClient(this._http, this._auth, this.bucket);

  final Http _http;
  final AuthClient _auth;
  final String bucket;

  String _url(String rest) => '/storage/v1$rest';

  /// Uploads a file to [path] (e.g. `avatars/me.png`). Fails with 409 if it exists, unless [upsert] is true.
  Future<StorageUploadResult> upload(
    String path,
    Uint8List bytes, {
    String contentType = 'application/octet-stream',
    bool upsert = false,
  }) async {
    final result = await _http.send(
      _url('/object/$bucket/${_encodePath(path)}'),
      method: 'POST',
      bytes: bytes,
      contentType: contentType,
      token: await _auth.accessToken(),
      extraHeaders: {if (upsert) 'x-upsert': 'true'},
    );
    return StorageUploadResult.fromJson(result.json! as Map<String, dynamic>);
  }

  /// Downloads a file the caller may read. With [transform], an image comes back resized (Pro and Group).
  Future<Uint8List> download(String path, {ImageTransform? transform}) async {
    final query = transform?.query ?? const <String, String>{};
    final route = query.isEmpty
        ? _url('/object/$bucket/${_encodePath(path)}')
        : _url('/render/image/authenticated/$bucket/${_encodePath(path)}');
    final result =
        await _http.send(route, query: query, token: await _auth.accessToken());
    return result.bodyBytes;
  }

  /// Files whose path starts with [prefix] (default: all), by name.
  Future<List<StorageFile>> list(
      {String prefix = '', int? limit, int? offset}) async {
    final result = await _http.send(
      _url('/object/list/$bucket'),
      method: 'POST',
      token: await _auth.accessToken(),
      jsonBody: {
        'prefix': prefix,
        if (limit != null) 'limit': limit,
        if (offset != null) 'offset': offset
      },
    );
    return [
      for (final f in result.json! as List<dynamic>)
        StorageFile.fromJson(f as Map<String, dynamic>)
    ];
  }

  /// Deletes files (up to 100). Returns what was actually removed.
  Future<List<StorageFile>> remove(List<String> paths) async {
    if (paths.isEmpty)
      throw EspobaseException.client(
          'invalid_paths', 'remove(): list at least one path.');
    final result = await _http.send(
      _url('/object/$bucket'),
      method: 'DELETE',
      token: await _auth.accessToken(),
      jsonBody: {'paths': paths},
    );
    return [
      for (final f in result.json! as List<dynamic>)
        StorageFile.fromJson(f as Map<String, dynamic>)
    ];
  }

  /// A link anyone can use to download the file for [expiresIn] seconds (max 7 days). With [transform], the link
  /// serves a resized image.
  Future<Uri> createSignedUrl(String path, int expiresIn,
      {ImageTransform? transform}) async {
    final json = await _http.jsonObject(
      _url('/object/sign/$bucket/${_encodePath(path)}'),
      method: 'POST',
      token: await _auth.accessToken(),
      body: {'expiresIn': expiresIn},
    );
    var url = Uri.parse(json['signedUrl'] as String);
    final query = transform?.query ?? const <String, String>{};
    if (query.isNotEmpty) {
      url = url.replace(
        path: url.path.replaceFirst('/object/sign/', '/render/image/sign/'),
        queryParameters: {...url.queryParameters, ...query},
      );
    }
    return url;
  }

  /// The permanent URL of a file in a PUBLIC bucket (no request is made; private buckets answer 404).
  Uri getPublicUrl(String path, {ImageTransform? transform}) {
    final query = transform?.query ?? const <String, String>{};
    final route = query.isEmpty
        ? _url('/object/public/$bucket/${_encodePath(path)}')
        : _url('/render/image/public/$bucket/${_encodePath(path)}');
    return _http.uri(route, query);
  }
}

/// Used by tests to build raw bodies.
Uint8List utf8Bytes(String text) => Uint8List.fromList(utf8.encode(text));
