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

  test(
    'write requests carry a 128-bit hex Idempotency-Key; GET does not',
    () async {
      String? postKey;
      var getHadKey = true;
      final client = DevApiClient(
        'http://127.0.0.1:8790',
        client: MockClient((request) async {
          if (request.method == 'POST') {
            postKey = request.headers['idempotency-key'];
          } else if (request.method == 'GET') {
            getHadKey = request.headers.containsKey('idempotency-key');
          }
          return http.Response(
            jsonEncode({'ok': true, 'data': <String, dynamic>{}}),
            200,
          );
        }),
      );
      await client.postData('/v1/movements/drafts', body: {'x': 1});
      await client.getData('/v1/accounts');
      expect(postKey, isNotNull);
      expect(postKey, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(getHadKey, isFalse);
    },
  );

  test('PATCH carries an Idempotency-Key', () async {
    String? key;
    final client = DevApiClient(
      'http://127.0.0.1:8790',
      client: MockClient((request) async {
        key = request.headers['idempotency-key'];
        return http.Response(
          jsonEncode({'ok': true, 'data': <String, dynamic>{}}),
          200,
        );
      }),
    );
    await client.patchData('/v1/dca/plans/plan_1', body: {'x': 1});
    expect(key, matches(RegExp(r'^[0-9a-f]{32}$')));
  });

  test('two independent writes use different Idempotency-Keys', () async {
    final keys = <String>[];
    final client = DevApiClient(
      'http://127.0.0.1:8790',
      client: MockClient((request) async {
        final k = request.headers['idempotency-key'];
        if (k != null) keys.add(k);
        return http.Response(
          jsonEncode({'ok': true, 'data': <String, dynamic>{}}),
          200,
        );
      }),
    );
    await client.postData('/v1/movements/drafts', body: {'x': 1});
    await client.postData('/v1/movements/drafts', body: {'x': 2});
    expect(keys, hasLength(2));
    expect(keys[0], isNot(keys[1]));
  });

  test(
    '401 replay reuses the same Idempotency-Key; auth refresh has none',
    () async {
      final store = MemoryAuthTokenStore();
      await store.write(
        const StoredAuthSession(
          accessToken: 'access_expired',
          refreshToken: 'refresh_old',
          expiresAt: '2026-07-13T12:00:00+08:00',
          deviceId: 'device_1',
        ),
      );
      final businessKeys = <String>[];
      var refreshHadKey = true;
      final client = DevApiClient(
        'http://127.0.0.1:8790',
        tokenStore: store,
        client: MockClient((request) async {
          if (request.url.path == '/v1/auth/refresh') {
            refreshHadKey = request.headers.containsKey('idempotency-key');
            return http.Response(
              jsonEncode({
                'ok': true,
                'data': {
                  'accessToken': 'access_new',
                  'refreshToken': 'refresh_new',
                  'expiresAt': '2026-07-13T13:00:00+08:00',
                  'deviceId': 'device_1',
                },
              }),
              200,
            );
          }
          final k = request.headers['idempotency-key'];
          if (k != null) businessKeys.add(k);
          if (request.headers['authorization'] == 'Bearer access_expired') {
            return http.Response(jsonEncode({'ok': false}), 401);
          }
          return http.Response(
            jsonEncode({
              'ok': true,
              'data': {'id': 'mov_1'},
            }),
            200,
          );
        }),
      );
      await client.postData('/v1/movements/drafts', body: {'x': 1});
      expect(businessKeys, hasLength(2)); // 首次(401) + 刷新后重放
      expect(businessKeys[0], businessKeys[1]); // 复用同一 key
      expect(refreshHadKey, isFalse); // auth refresh 不带业务幂等 key
    },
  );

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
    // refresh 也明确 401：会话确定失效，必须清除本地 token
    // （网络失败/5xx 仍保留，见 agent_expired_session_test）。
    expect(await store.read(), isNull);
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
