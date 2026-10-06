# Espobase for Dart and Flutter

The Espobase client for Dart and Flutter: your project's database, App Authentication (including Sign in with Apple),
Storage and edge functions. Pure Dart (works in Flutter apps on iOS, Android and the web, and in server-side Dart). Depends
only on `http` and `crypto`. Requires Dart 3.

> Version 0.1.0. Realtime (WebSockets) is not in this version: use the REST API, or the JavaScript client for realtime.

## Install

```yaml
dependencies:
  espobase: ^0.1.0
```

## Create a client

```dart
import 'package:espobase/espobase.dart';

final espobase = EspobaseClient(
  'https://api.espobase.com/project/<your project ref>',
  'eb_pk_…', // the PUBLISHABLE key: safe in an app
);
```

Never put a secret key (`eb_sk_…`) in an app: `EspobaseClient` refuses it unless `ClientOptions(serverSide: true)` (for a
trusted server).

## Database

```dart
final todos = await espobase.from('todos').select().eq('done', false).order('created_at', ascending: false).limit(20);

await espobase.from('todos').insert({'title': 'Buy milk'});
final created = await espobase.from('todos').insert({'title': 'Walk the dog'}).select();
await espobase.from('todos').update({'done': true}).eq('id', 1);
await espobase.from('todos').delete().eq('id', 1);
final one = await espobase.from('todos').select().eq('id', 1).single();
```

Rows are `Map<String, dynamic>`. `update()` and `delete()` refuse to run without a filter. Filters: `eq neq gt gte lt lte like
ilike inList isNull isBool`; `order`, `limit`, `range`, `single()`. Every method returns a new query, so a base query can
be reused. Database functions: `await espobase.rpc('match_documents', params: {...})`. Row level security applies to
everything, as the signed-in user.

## Sign-up and sign-in

```dart
await espobase.auth.signUp(email: email, password: password, redirectTo: 'myapp://auth/callback');
final session = await espobase.auth.signInWithPassword(email: email, password: password);

espobase.auth.onAuthStateChange.listen((change) { /* change.event, change.session */ });
```

By default the session lives in memory. To stay signed in across launches, give the client a `SessionStorage` backed by
`flutter_secure_storage`:

```dart
class SecureSessionStorage implements SessionStorage {
  final _store = const FlutterSecureStorage();
  @override Future<String?> get(String key) => _store.read(key: key);
  @override Future<void> set(String key, String value) => _store.write(key: key, value: value);
  @override Future<void> remove(String key) => _store.delete(key: key);
}

final espobase = EspobaseClient(url, key, options: ClientOptions(sessionStorage: SecureSessionStorage()));
```

Add your app link (`myapp://auth/callback`) under Authentication › Settings › Allowed redirect URLs for confirmation and
password-reset emails.

### Sign in with Apple

Turn it on under Authentication › Providers › Apple, with your bundle ID. With the `sign_in_with_apple` package:

```dart
final nonce = AppleNonce();
final credential = await SignInWithApple.getAppleIDCredential(
  scopes: [AppleIDAuthorizationScopes.email],
  nonce: nonce.hashed, // Apple gets the hash …
);
final session = await espobase.auth.signInWithIdToken(token: credential.identityToken!, nonce: nonce.raw); // … Espobase the raw value
```

### Google, GitHub

```dart
final url = await espobase.auth.signInWithOAuth(provider: OAuthProvider.google, redirectTo: 'myapp://auth/callback');
// open it with flutter_web_auth_2 (callbackUrlScheme: 'myapp'); the result URL has ?code=…
final result = await FlutterWebAuth2.authenticate(url: url.toString(), callbackUrlScheme: 'myapp');
final session = await espobase.auth.exchangeCodeForSession(Uri.parse(result).queryParameters['code']!);
```

Only this device can finish the sign-in (PKCE). A sign-in that needs a second step throws `mfa_required`; finish it with
`espobase.auth.mfa.verify(code: …)`.

## Storage

```dart
final photos = espobase.storage.from('photos');
await photos.upload('$userId/me.jpg', bytes, contentType: 'image/jpeg');
final data = await photos.download('$userId/me.jpg');
final thumb = photos.getPublicUrl('logo.png', transform: const ImageTransform(width: 200)); // Pro and Group
final link = await photos.createSignedUrl('$userId/me.jpg', 600);
```

## Edge functions

```dart
final answer = await espobase.functions.invoke('hello', body: {'name': 'Ada'});
print(answer.data); // parsed JSON for application/json
```

## Errors

Everything throws `EspobaseException` (`status`, `code`, `message`, `details`, `hint`); `status` is 0 for network and
client-side errors.

## Tests

`dart test` (23 tests with a mock `http.Client`: no network). `dart analyze` is clean.
