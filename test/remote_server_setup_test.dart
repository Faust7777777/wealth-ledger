import 'dart:io';

import 'package:finwealth/core/api_endpoint_store.dart';
import 'package:finwealth/core/env.dart';
import 'package:finwealth/app/app.dart';
import 'package:finwealth/data/auth_store.dart';
import 'package:finwealth/data/providers.dart';
import 'package:finwealth/features/remote_server_setup_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('HTTPS origin normalization rejects unsafe endpoint shapes', () {
    expect(
      normalizeHttpsApiOrigin(' https://API.Example.com/ '),
      'https://api.example.com',
    );
    expect(
      normalizeHttpsApiOrigin('https://api.example.com:8443'),
      'https://api.example.com:8443',
    );
    for (final invalid in [
      'http://api.example.com',
      'https://user:pass@api.example.com',
      'https://api.example.com/base',
      'https://api.example.com?x=1',
      'not-a-url',
    ]) {
      expect(
        () => normalizeHttpsApiOrigin(invalid),
        throwsA(isA<FormatException>()),
      );
    }
  });

  test('Windows-compatible endpoint file round-trips validated JSON', () async {
    final directory = await Directory.systemTemp.createTemp(
      'finwealth-endpoint-store-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}${Platform.pathSeparator}server.json');
    final store = PlatformApiEndpointStore(file: file);

    await store.write('https://api.example.com/');
    expect(await store.read(), 'https://api.example.com');
    expect(await file.readAsString(), contains('"version":1'));
    await store.clear();
    expect(await store.read(), isNull);
  });

  test(
    'persisted endpoint becomes the effective API origin after restart',
    () async {
      final container = ProviderContainer(
        overrides: [
          appEnvironmentProvider.overrideWithValue(
            const AppEnvironment(
              dataSourceMode: DataSourceMode.apiRemote,
              apiBaseUrl: '',
            ),
          ),
          apiEndpointStoreProvider.overrideWithValue(
            MemoryApiEndpointStore('https://api.example.com'),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(remoteApiEndpointProvider.future);
      expect(
        container.read(effectiveAppEnvironmentProvider).apiBaseUrl,
        'https://api.example.com',
      );
    },
  );

  testWidgets('api_remote with no endpoint boots into server setup', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appEnvironmentProvider.overrideWithValue(
            const AppEnvironment(
              dataSourceMode: DataSourceMode.apiRemote,
              apiBaseUrl: '',
            ),
          ),
          apiEndpointStoreProvider.overrideWithValue(MemoryApiEndpointStore()),
        ],
        child: const WealthLedgerApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('连接服务器'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets(
    'server setup verifies health, saves endpoint, and clears old tokens',
    (tester) async {
      final endpointStore = MemoryApiEndpointStore();
      final tokenStore = MemoryAuthTokenStore();
      await tokenStore.write(_session);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appEnvironmentProvider.overrideWithValue(
              const AppEnvironment(
                dataSourceMode: DataSourceMode.apiRemote,
                apiBaseUrl: '',
              ),
            ),
            apiEndpointStoreProvider.overrideWithValue(endpointStore),
            authTokenStoreProvider.overrideWithValue(tokenStore),
            remoteServerHealthProbeProvider.overrideWithValue((_) async {}),
          ],
          child: const MaterialApp(home: RemoteServerSetupPage()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byType(TextField),
        ' https://API.Example.com/ ',
      );
      await tester.tap(find.widgetWithText(FilledButton, '连接'));
      await tester.pumpAndSettle();

      expect(await endpointStore.read(), 'https://api.example.com');
      expect(await tokenStore.read(), isNull);
    },
  );

  testWidgets('failed health check keeps endpoint and tokens unchanged', (
    tester,
  ) async {
    final endpointStore = MemoryApiEndpointStore();
    final tokenStore = MemoryAuthTokenStore();
    await tokenStore.write(_session);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appEnvironmentProvider.overrideWithValue(
            const AppEnvironment(
              dataSourceMode: DataSourceMode.apiRemote,
              apiBaseUrl: '',
            ),
          ),
          apiEndpointStoreProvider.overrideWithValue(endpointStore),
          authTokenStoreProvider.overrideWithValue(tokenStore),
          remoteServerHealthProbeProvider.overrideWithValue(
            (_) async => throw StateError('不可达'),
          ),
        ],
        child: const MaterialApp(home: RemoteServerSetupPage()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'https://api.example.com');
    await tester.tap(find.widgetWithText(FilledButton, '连接'));
    await tester.pumpAndSettle();

    expect(find.text('不可达'), findsOneWidget);
    expect(await endpointStore.read(), isNull);
    expect(await tokenStore.read(), isNotNull);
  });
}

const _session = StoredAuthSession(
  accessToken: 'access',
  refreshToken: 'refresh',
  expiresAt: '2026-07-15T00:00:00Z',
  deviceId: 'device',
);
