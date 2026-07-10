import 'dart:convert';
import 'dart:io';

import 'package:finwealth/data/api_mock_repositories.dart';
import 'package:finwealth/data/auth_repositories.dart';
import 'package:finwealth/data/auth_store.dart';
import 'package:finwealth/data/auth_token_store_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('DevApiClient attaches bearer token from token store', () async {
    final store = MemoryAuthTokenStore();
    await store.write(
      const StoredAuthSession(
        accessToken: 'access_123',
        refreshToken: 'refresh_123',
        expiresAt: '2026-06-29T12:00:00+08:00',
        deviceId: 'device_1',
      ),
    );

    final client = DevApiClient(
      'http://127.0.0.1:8790',
      tokenStore: store,
      client: MockClient((request) async {
        expect(request.headers['authorization'], 'Bearer access_123');
        return http.Response(
          jsonEncode({
            'ok': true,
            'data': {'healthy': true},
          }),
          200,
        );
      }),
    );

    final data = await client.getData('/v1/health');
    expect((data as Map)['healthy'], isTrue);
  });

  test('DevApiClient maps 401 to ApiUnauthorizedException', () async {
    final client = DevApiClient(
      'http://127.0.0.1:8790',
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'ok': false,
            'error': {'code': 'auth_required'},
          }),
          401,
        ),
      ),
    );

    await expectLater(
      client.getData('/v1/accounts'),
      throwsA(isA<ApiUnauthorizedException>()),
    );
  });

  test('DevApiClient refreshes session on 401 and replays request', () async {
    final store = MemoryAuthTokenStore();
    await store.write(
      const StoredAuthSession(
        accessToken: 'access_expired',
        refreshToken: 'refresh_old',
        expiresAt: '2026-07-07T12:00:00+08:00',
        deviceId: 'device_1',
      ),
    );

    var refreshCalls = 0;
    final client = DevApiClient(
      'http://127.0.0.1:8790',
      tokenStore: store,
      client: MockClient((request) async {
        if (request.url.path == '/v1/auth/refresh') {
          refreshCalls++;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['refreshToken'], 'refresh_old');
          return http.Response(
            jsonEncode({
              'ok': true,
              'data': {
                'accessToken': 'access_new',
                'refreshToken': 'refresh_new',
                'expiresAt': '2026-07-07T13:00:00+08:00',
                'deviceId': 'device_1',
              },
            }),
            200,
          );
        }
        if (request.headers['authorization'] == 'Bearer access_expired') {
          return http.Response(jsonEncode({'ok': false}), 401);
        }
        expect(request.headers['authorization'], 'Bearer access_new');
        return http.Response(
          jsonEncode({
            'ok': true,
            'data': {
              'items': ['acct_1'],
            },
          }),
          200,
        );
      }),
    );

    final data = await client.getData('/v1/accounts');
    expect((data as Map)['items'], ['acct_1']);
    expect(refreshCalls, 1);
    final stored = await store.read();
    expect(stored?.accessToken, 'access_new');
    expect(stored?.refreshToken, 'refresh_new');
  });

  test('DevApiClient surfaces 401 when refresh fails', () async {
    final store = MemoryAuthTokenStore();
    await store.write(
      const StoredAuthSession(
        accessToken: 'access_expired',
        refreshToken: 'refresh_revoked',
        expiresAt: '2026-07-07T12:00:00+08:00',
        deviceId: 'device_1',
      ),
    );

    final client = DevApiClient(
      'http://127.0.0.1:8790',
      tokenStore: store,
      client: MockClient((request) async {
        if (request.url.path == '/v1/auth/refresh') {
          return http.Response(jsonEncode({'ok': false}), 401);
        }
        return http.Response(jsonEncode({'ok': false}), 401);
      }),
    );

    await expectLater(
      client.getData('/v1/accounts'),
      throwsA(isA<ApiUnauthorizedException>()),
    );
    // refresh 失败不得破坏本地会话（留给用户手动重新登录）。
    final stored = await store.read();
    expect(stored?.refreshToken, 'refresh_revoked');
  });

  test(
    'LocalServerAuthRepository parses login response without storing password',
    () async {
      final client = DevApiClient(
        'http://127.0.0.1:8790',
        client: MockClient((request) async {
          expect(request.url.path, '/v1/auth/login');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['username'], 'wu');
          expect(body['password'], 'correct horse');
          expect(body['deviceName'], 'Windows device');
          return http.Response(
            jsonEncode({
              'ok': true,
              'data': {
                'accessToken': 'access_abc',
                'refreshToken': 'refresh_abc',
                'expiresAt': '2026-06-29T12:00:00+08:00',
                'deviceId': 'device_1',
              },
            }),
            200,
          );
        }),
      );

      final session = await LocalServerAuthRepository(client).login(
        username: 'wu',
        password: 'correct horse',
        deviceName: 'Windows device',
      );

      expect(session.accessToken, 'access_abc');
      expect(session.refreshToken, 'refresh_abc');
      expect(session.deviceId, 'device_1');
    },
  );

  test(
    'PlatformAuthTokenStore protects token file with Windows DPAPI',
    () async {
      if (!Platform.isWindows) return;
      final dir = await Directory.systemTemp.createTemp('finwealth_auth_test_');
      final file = File('${dir.path}\\auth_tokens.dpapi');
      final store = PlatformAuthTokenStore(file: file);
      try {
        await store.write(
          const StoredAuthSession(
            accessToken: 'access_plain_must_not_leak',
            refreshToken: 'refresh_plain_must_not_leak',
            expiresAt: '2026-06-29T12:00:00+08:00',
            deviceId: 'device_1',
          ),
        );

        final raw = await file.readAsBytes();
        final rawText = utf8.decode(raw, allowMalformed: true);
        expect(rawText, isNot(contains('access_plain_must_not_leak')));
        expect(rawText, isNot(contains('refresh_plain_must_not_leak')));

        final restored = await store.read();
        expect(restored?.accessToken, 'access_plain_must_not_leak');
        expect(restored?.refreshToken, 'refresh_plain_must_not_leak');

        await store.clear();
        expect(await file.exists(), isFalse);
      } finally {
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
      }
    },
  );
}
