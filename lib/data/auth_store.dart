// Wealth Ledger — frontend auth token persistence.
// Stores only opaque server tokens. Never store usernames/passwords.
import 'package:flutter/foundation.dart';

@immutable
class StoredAuthSession {
  const StoredAuthSession({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    required this.deviceId,
  });

  final String accessToken;
  final String refreshToken;
  final String expiresAt;
  final String deviceId;

  bool get isComplete =>
      accessToken.isNotEmpty &&
      refreshToken.isNotEmpty &&
      expiresAt.isNotEmpty &&
      deviceId.isNotEmpty;
}

abstract interface class AuthTokenStore {
  Future<StoredAuthSession?> read();
  Future<String?> readAccessToken();
  Future<void> write(StoredAuthSession session);
  Future<void> clear();
}

class MemoryAuthTokenStore implements AuthTokenStore {
  StoredAuthSession? _session;

  @override
  Future<StoredAuthSession?> read() async => _session;

  @override
  Future<String?> readAccessToken() async => _session?.accessToken;

  @override
  Future<void> write(StoredAuthSession session) async {
    _session = session;
  }

  @override
  Future<void> clear() async {
    _session = null;
  }
}
