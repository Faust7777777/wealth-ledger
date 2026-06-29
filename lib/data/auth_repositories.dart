// Wealth Ledger — local server authentication repository.
import 'package:flutter/foundation.dart';

import 'api_mock_repositories.dart';
import 'auth_store.dart';

@immutable
class AuthSessionVm extends StoredAuthSession {
  const AuthSessionVm({
    required super.accessToken,
    required super.refreshToken,
    required super.expiresAt,
    required super.deviceId,
  });

  factory AuthSessionVm.fromJson(Map<String, dynamic> json) => AuthSessionVm(
    accessToken: (json['accessToken'] ?? '').toString(),
    refreshToken: (json['refreshToken'] ?? '').toString(),
    expiresAt: (json['expiresAt'] ?? '').toString(),
    deviceId: (json['deviceId'] ?? '').toString(),
  );
}

@immutable
class AuthDeviceVm {
  const AuthDeviceVm({
    required this.id,
    required this.name,
    required this.createdAt,
    this.lastSeenAt,
  });

  factory AuthDeviceVm.fromJson(Map<String, dynamic> json) => AuthDeviceVm(
    id: (json['id'] ?? '').toString(),
    name: (json['name'] ?? '').toString(),
    createdAt: (json['createdAt'] ?? '').toString(),
    lastSeenAt: json['lastSeenAt']?.toString(),
  );

  final String id;
  final String name;
  final String createdAt;
  final String? lastSeenAt;
}

abstract interface class AuthRepository {
  Future<AuthSessionVm> login({
    required String username,
    required String password,
    required String deviceName,
  });
  Future<AuthSessionVm> refresh(String refreshToken);
  Future<void> logout(String refreshToken);
  Future<List<AuthDeviceVm>> listDevices();
  Future<void> revokeDevice(String deviceId);
}

class LocalServerAuthRepository implements AuthRepository {
  const LocalServerAuthRepository(this._client);

  final DevApiClient _client;

  @override
  Future<AuthSessionVm> login({
    required String username,
    required String password,
    required String deviceName,
  }) async {
    final data = await _client.postData(
      '/v1/auth/login',
      body: {
        'username': username,
        'password': password,
        'deviceName': deviceName,
      },
    );
    return AuthSessionVm.fromJson(_map(data));
  }

  @override
  Future<AuthSessionVm> refresh(String refreshToken) async {
    final data = await _client.postData(
      '/v1/auth/refresh',
      body: {'refreshToken': refreshToken},
    );
    return AuthSessionVm.fromJson(_map(data));
  }

  @override
  Future<void> logout(String refreshToken) async {
    await _client.postData(
      '/v1/auth/logout',
      body: {'refreshToken': refreshToken},
    );
  }

  @override
  Future<List<AuthDeviceVm>> listDevices() async {
    final data = await _client.getData('/v1/auth/devices');
    final list = data is List
        ? data
        : (data is Map && data['items'] is List
              ? data['items'] as List
              : const []);
    return list.map((item) => AuthDeviceVm.fromJson(_map(item))).toList();
  }

  @override
  Future<void> revokeDevice(String deviceId) async {
    await _client.postData('/v1/auth/devices/$deviceId/revoke');
  }
}

class UnsupportedAuthRepository implements AuthRepository {
  const UnsupportedAuthRepository();

  UnsupportedError _unsupported() =>
      UnsupportedError('当前数据源不支持登录；请用 DATA_SOURCE=local_server');

  @override
  Future<AuthSessionVm> login({
    required String username,
    required String password,
    required String deviceName,
  }) async => throw _unsupported();

  @override
  Future<AuthSessionVm> refresh(String refreshToken) async =>
      throw _unsupported();

  @override
  Future<void> logout(String refreshToken) async => throw _unsupported();

  @override
  Future<List<AuthDeviceVm>> listDevices() async => const [];

  @override
  Future<void> revokeDevice(String deviceId) async => throw _unsupported();
}

Map<String, dynamic> _map(Object? data) =>
    (data as Map).cast<String, dynamic>();
