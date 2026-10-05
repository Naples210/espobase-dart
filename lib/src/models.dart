import 'errors.dart';

/// How a user signs in: email + password, or a social sign-in provider.
enum AuthProvider {
  email,
  google,
  github,
  apple;

  static AuthProvider parse(String value) => AuthProvider.values
      .firstWhere((p) => p.name == value, orElse: () => AuthProvider.email);
}

/// Social sign-in providers (turned on per project in the dashboard).
enum OAuthProvider { google, github, apple }

class User {
  const User({
    required this.id,
    required this.email,
    required this.emailVerified,
    required this.appRole,
    required this.provider,
    required this.providers,
    required this.createdAt,
    this.lastSignInAt,
  });

  final String id;
  final String email;
  final bool emailVerified;
  final String appRole;

  /// The first way this user signed in.
  final AuthProvider provider;

  /// Every sign-in method linked to the user.
  final List<AuthProvider> providers;
  final String createdAt;
  final String? lastSignInAt;

  factory User.fromJson(Map<String, dynamic> json) => User(
        id: json['id'] as String,
        email: json['email'] as String,
        emailVerified: json['emailVerified'] as bool,
        appRole: json['appRole'] as String,
        provider: AuthProvider.parse(json['provider'] as String),
        providers: (json['providers'] as List<dynamic>)
            .map((p) => AuthProvider.parse(p as String))
            .toList(),
        createdAt: json['createdAt'] as String,
        lastSignInAt: json['lastSignInAt'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'email': email,
        'emailVerified': emailVerified,
        'appRole': appRole,
        'provider': provider.name,
        'providers': providers.map((p) => p.name).toList(),
        'createdAt': createdAt,
        'lastSignInAt': lastSignInAt,
      };
}

class Session {
  const Session({
    required this.accessToken,
    required this.tokenType,
    required this.expiresIn,
    required this.expiresAt,
    required this.refreshToken,
    required this.user,
  });

  final String accessToken;
  final String tokenType;
  final int expiresIn;

  /// Epoch seconds.
  final int expiresAt;
  final String refreshToken;
  final User user;

  factory Session.fromJson(Map<String, dynamic> json) => Session(
        accessToken: json['access_token'] as String,
        tokenType: json['token_type'] as String,
        expiresIn: json['expires_in'] as int,
        expiresAt: json['expires_at'] as int,
        refreshToken: json['refresh_token'] as String,
        user: User.fromJson(json['user'] as Map<String, dynamic>),
      );

  Map<String, dynamic> toJson() => {
        'access_token': accessToken,
        'token_type': tokenType,
        'expires_in': expiresIn,
        'expires_at': expiresAt,
        'refresh_token': refreshToken,
        'user': user.toJson(),
      };

  Session withUser(User next) => Session(
        accessToken: accessToken,
        tokenType: tokenType,
        expiresIn: expiresIn,
        expiresAt: expiresAt,
        refreshToken: refreshToken,
        user: next,
      );
}

enum AuthEvent { signedIn, signedOut, tokenRefreshed, userUpdated }

class AuthStateChange {
  const AuthStateChange(this.event, this.session);

  final AuthEvent event;
  final Session? session;
}

class SignUpResult {
  const SignUpResult({this.user, this.session});

  /// The new account; [session] is null while the email still has to be confirmed.
  final User? user;
  final Session? session;
}

class MfaFactor {
  const MfaFactor(
      {required this.id,
      required this.type,
      required this.verified,
      required this.createdAt});

  final String id;
  final MfaFactorType type;
  final bool verified;
  final String createdAt;

  factory MfaFactor.fromJson(Map<String, dynamic> json) => MfaFactor(
        id: json['id'] as String,
        type: MfaFactorType.parse(json['type'] as String),
        verified: json['verified'] as bool,
        createdAt: json['createdAt'] as String,
      );
}

/// A Storage file, as listed.
class StorageFile {
  const StorageFile({
    required this.id,
    required this.name,
    required this.size,
    required this.mimeType,
    required this.sha256,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;

  /// Full path in the bucket, e.g. `avatars/me.png`.
  final String name;
  final int size;
  final String? mimeType;
  final String? sha256;
  final String createdAt;
  final String updatedAt;

  factory StorageFile.fromJson(Map<String, dynamic> json) => StorageFile(
        id: json['id'] as String,
        name: json['name'] as String,
        size: json['size'] as int,
        mimeType: json['mimeType'] as String?,
        sha256: json['sha256'] as String?,
        createdAt: json['createdAt'] as String,
        updatedAt: json['updatedAt'] as String,
      );
}

class StorageUploadResult {
  const StorageUploadResult({
    required this.id,
    required this.bucket,
    required this.path,
    required this.size,
    required this.sha256,
  });

  final String id;
  final String bucket;
  final String path;
  final int size;

  /// SHA-256 of the stored bytes (hex).
  final String sha256;

  factory StorageUploadResult.fromJson(Map<String, dynamic> json) =>
      StorageUploadResult(
        id: json['id'] as String,
        bucket: json['bucket'] as String,
        path: json['path'] as String,
        size: json['size'] as int,
        sha256: json['sha256'] as String,
      );
}

/// Resizing for stored images (Pro and Group). Give a width, a height or both.
class ImageTransform {
  const ImageTransform(
      {this.width, this.height, this.resize, this.quality, this.format});

  final int? width;
  final int? height;

  /// `cover` (default), `contain`, `fill`, `inside` or `outside`.
  final String? resize;
  final int? quality;

  /// `webp` (default), `jpeg`, `png` or `avif`.
  final String? format;

  Map<String, String> get query => {
        if (width != null) 'width': '$width',
        if (height != null) 'height': '$height',
        if (resize != null) 'resize': resize!,
        if (quality != null) 'quality': '$quality',
        if (format != null) 'format': format!,
      };
}
