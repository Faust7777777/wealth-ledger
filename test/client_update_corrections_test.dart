// 2026-07-29 修正单：P0.1 启动静默检查、P0.2 HTTPS origin 门禁、
// P0.3 失败/极早取消不得遗留半包、P1 授权返回后可继续安装，
// 以及 manifest 的窄校验。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:finwealth/app/app.dart';
import 'package:finwealth/core/env.dart';
import 'package:finwealth/data/client_update.dart';
import 'package:finwealth/data/providers.dart';
import 'package:finwealth/features/app_update_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _base = 'https://wuwaidut.com';
final _body = utf8.encode('APK!');

Map<String, dynamic> _manifestJson({
  int versionCode = 3,
  int? sizeBytes,
  String? sha,
  String fileName = 'finwealth-1.1.0-android.apk',
  String platform = 'android',
}) => {
  'schemaVersion': 1,
  'platform': platform,
  'channel': 'stable',
  'versionName': '1.1.0',
  'versionCode': versionCode,
  'releasedAt': '2026-07-29T12:00:00Z',
  'mandatory': false,
  'notes': const ['加入应用内更新'],
  'asset': {
    'url': '/v1/client-updates/android/stable/assets/$fileName',
    'fileName': fileName,
    'sizeBytes': sizeBytes ?? _body.length,
    'sha256': sha ?? sha256.convert(_body).toString(),
    'contentType': 'application/vnd.android.package-archive',
  },
};

Directory _tempDir() {
  final dir = Directory.systemTemp.createTempSync('finwealth-fix-test');
  addTearDown(() {
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (_) {
      // Windows 句柄延迟释放：交给系统回收。
    }
  });
  return dir;
}

ClientUpdateService _service(
  http.Client client, {
  required Directory dir,
  String base = _base,
}) => ClientUpdateService(
  apiBaseUrl: base,
  platform: 'android',
  cacheDirProvider: () async => dir.path,
  client: client,
);

class _FakePlatform implements ClientUpdatePlatform {
  _FakePlatform({this.canInstall = true});
  bool canInstall;
  final List<String> installed = [];
  int permissionOpens = 0;

  @override
  Future<InstalledVersionVm> installedVersion() async =>
      const InstalledVersionVm(versionName: '1.1.0', versionCode: 2);
  @override
  Future<String> updateCacheDir() async => '';
  @override
  Future<bool> canInstallPackages() async => canInstall;
  @override
  Future<void> openInstallPermissionSettings() async => permissionOpens += 1;
  @override
  Future<void> openInstaller(String path) async => installed.add(path);
}

void main() {
  group('P0.2 HTTPS origin 门禁', () {
    test('非 HTTPS origin 一律拒绝', () {
      for (final base in [
        'http://wuwaidut.com',
        'http://127.0.0.1:8791',
        'ftp://wuwaidut.com',
        'wuwaidut.com',
        '',
      ]) {
        expect(
          () => resolveUpdateAssetUrl(base, '/v1/x/app.apk'),
          throwsA(isA<ClientUpdateRejected>()),
          reason: base,
        );
      }
    });

    test('带 userInfo / query / fragment / 业务路径的 base 被拒绝', () {
      for (final base in [
        'https://user:pass@wuwaidut.com',
        'https://wuwaidut.com?x=1',
        'https://wuwaidut.com#frag',
        'https://wuwaidut.com/api',
      ]) {
        expect(
          () => requireHttpsOrigin(base),
          throwsA(isA<ClientUpdateRejected>()),
          reason: base,
        );
      }
    });

    test('干净 HTTPS origin + 合法相对资源保持同源', () {
      final uri = resolveUpdateAssetUrl(
        _base,
        '/v1/client-updates/android/stable/assets/app.apk',
      );
      expect(uri.origin, _base);
      expect(uri.scheme, 'https');
      expect(uri.path, '/v1/client-updates/android/stable/assets/app.apk');
      expect(requireHttpsOrigin('https://wuwaidut.com/').host, 'wuwaidut.com');
    });

    test('更新服务只在 Android + apiRemote + HTTPS 下存在', () {
      ProviderContainer containerFor(AppEnvironment env) {
        final container = ProviderContainer(
          overrides: [
            clientUpdatePlatformProvider.overrideWithValue(_FakePlatform()),
            appEnvironmentProvider.overrideWithValue(env),
          ],
        );
        addTearDown(container.dispose);
        return container;
      }

      expect(
        containerFor(
          const AppEnvironment(
            dataSourceMode: DataSourceMode.apiRemote,
            apiBaseUrl: _base,
          ),
        ).read(clientUpdateServiceProvider),
        isNotNull,
      );
      // local_server（loopback HTTP）不检查更新。
      expect(
        containerFor(
          const AppEnvironment(
            dataSourceMode: DataSourceMode.localServer,
            apiBaseUrl: 'http://127.0.0.1:8791',
          ),
        ).read(clientUpdateServiceProvider),
        isNull,
      );
      // apiRemote 但地址不是 HTTPS：同样不提供更新。
      expect(
        containerFor(
          const AppEnvironment(
            dataSourceMode: DataSourceMode.apiRemote,
            apiBaseUrl: 'http://wuwaidut.com',
          ),
        ).read(clientUpdateServiceProvider),
        isNull,
      );
      // 尚未配置远端地址。
      expect(
        containerFor(
          const AppEnvironment(
            dataSourceMode: DataSourceMode.apiRemote,
            apiBaseUrl: '',
          ),
        ).read(clientUpdateServiceProvider),
        isNull,
      );
    });
  });

  group('P0.3 失败与取消不得遗留半包', () {
    test('收到首块后 stream 抛错：目录为空', () async {
      final dir = _tempDir();
      final chunks = StreamController<List<int>>();
      final service = _service(
        MockClient.streaming(
          (_, _) async => http.StreamedResponse(chunks.stream, 200),
        ),
        dir: dir,
      );
      final future = service.download(
        parseClientUpdateManifest(_manifestJson()),
      );
      chunks.add(utf8.encode('AP'));
      await Future<void>.delayed(Duration.zero);
      chunks.addError(const SocketException('broken'));
      await expectLater(future, throwsA(isA<ClientUpdateRejected>()));
      await chunks.close();
      expect(dir.listSync(), isEmpty, reason: '流错误必须删除半包');
    });

    test('极早取消（订阅建立前）：不下载、不遗留文件', () async {
      final dir = _tempDir();
      var streamed = 0;
      final cancel = Completer<void>()..complete();
      final service = _service(
        MockClient.streaming((_, _) async {
          streamed += 1;
          return http.StreamedResponse(Stream.value(_body), 200);
        }),
        dir: dir,
      );
      await expectLater(
        service.download(
          parseClientUpdateManifest(_manifestJson()),
          cancel: cancel.future,
        ),
        throwsA(isA<ClientUpdateRejected>()),
      );
      expect(dir.listSync(), isEmpty);
      expect(streamed, lessThanOrEqualTo(1), reason: '极早取消不应继续下载');
    });

    test('下载中取消：等订阅终止后删除半包', () async {
      final dir = _tempDir();
      final cancel = Completer<void>();
      final chunks = StreamController<List<int>>();
      final service = _service(
        MockClient.streaming(
          (_, _) async => http.StreamedResponse(chunks.stream, 200),
        ),
        dir: dir,
      );
      final future = service.download(
        parseClientUpdateManifest(_manifestJson()),
        cancel: cancel.future,
        onProgress: (_, _) {
          if (!cancel.isCompleted) cancel.complete();
        },
      );
      chunks.add(utf8.encode('AP'));
      await expectLater(future, throwsA(isA<ClientUpdateRejected>()));
      await chunks.close();
      expect(dir.listSync(), isEmpty);
    });

    test('非 200 响应：不落文件', () async {
      final dir = _tempDir();
      final service = _service(
        MockClient.streaming(
          (_, _) async => http.StreamedResponse(const Stream.empty(), 500),
        ),
        dir: dir,
      );
      await expectLater(
        service.download(parseClientUpdateManifest(_manifestJson())),
        throwsA(isA<ClientUpdateRejected>()),
      );
      expect(dir.listSync(), isEmpty);
    });

    test('成功路径仍是逐块写盘', () async {
      final dir = _tempDir();
      final service = _service(
        MockClient.streaming(
          (_, _) async => http.StreamedResponse(
            Stream.fromIterable([_body.sublist(0, 2), _body.sublist(2)]),
            200,
            contentLength: _body.length,
          ),
        ),
        dir: dir,
      );
      final progress = <int>[];
      final file = await service.download(
        parseClientUpdateManifest(_manifestJson()),
        onProgress: (received, _) => progress.add(received),
      );
      expect(progress, [2, 4]);
      expect(file.lengthSync(), _body.length);
    });
  });

  group('manifest 窄校验', () {
    test('versionCode / sizeBytes 必须为正', () {
      expect(
        () => parseClientUpdateManifest(_manifestJson(versionCode: 0)),
        throwsA(isA<ClientUpdateRejected>()),
      );
      expect(
        () => parseClientUpdateManifest(_manifestJson(sizeBytes: 0)),
        throwsA(isA<ClientUpdateRejected>()),
      );
    });

    test('SHA-256 必须是 64 位十六进制（大写按小写归一）', () {
      for (final bad in ['', 'zz', 'a' * 63, 'a' * 65, 'g' * 64]) {
        expect(
          () => parseClientUpdateManifest(_manifestJson(sha: bad)),
          throwsA(isA<ClientUpdateRejected>()),
          reason: bad,
        );
      }
      // 大写十六进制仍是合法摘要，归一成小写后再比对。
      expect(
        parseClientUpdateManifest(_manifestJson(sha: 'A' * 64)).asset.sha256,
        'a' * 64,
      );
    });

    test('Android 资源必须是安全的 .apk 文件名', () {
      for (final bad in [
        '../evil.apk',
        'evil.apk/../x',
        'evil.exe',
        '.hidden.apk',
        'a b.apk',
      ]) {
        expect(
          () => parseClientUpdateManifest(_manifestJson(fileName: bad)),
          throwsA(isA<ClientUpdateRejected>()),
          reason: bad,
        );
      }
      expect(
        parseClientUpdateManifest(
          _manifestJson(fileName: 'finwealth-1.1.0-android.apk'),
        ).asset.fileName,
        'finwealth-1.1.0-android.apk',
      );
    });
  });

  group('P0.1 启动静默检查', () {
    Widget appHost({
      required AppEnvironment env,
      required http.Client client,
      ClientUpdatePlatform? platform,
    }) => ProviderScope(
      overrides: [
        appEnvironmentProvider.overrideWithValue(env),
        clientUpdatePlatformProvider.overrideWithValue(platform),
        clientUpdateServiceProvider.overrideWith((ref) {
          if (platform == null) return null;
          final current = ref.watch(effectiveAppEnvironmentProvider);
          if (current.dataSourceMode != DataSourceMode.apiRemote) return null;
          if (!current.hasConfiguredRemoteApi) return null;
          return ClientUpdateService(
            apiBaseUrl: current.apiBaseUrl,
            platform: 'android',
            cacheDirProvider: () async => '',
            client: client,
          );
        }),
      ],
      child: const WealthLedgerApp(),
    );

    testWidgets('Android 启动后不进设置页也恰好检查一次', (tester) async {
      var checks = 0;
      await tester.pumpWidget(
        appHost(
          env: const AppEnvironment(
            dataSourceMode: DataSourceMode.apiRemote,
            apiBaseUrl: _base,
          ),
          platform: _FakePlatform(),
          client: MockClient((request) async {
            if (request.url.path.endsWith('/latest')) checks += 1;
            return http.Response('{}', 404);
          }),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(checks, 1, reason: '启动后应恰好检查一次');
      expect(find.byType(Scaffold), findsWidgets, reason: '不阻塞首屏');
    });

    testWidgets('rebuild 与切主题不产生第二次请求', (tester) async {
      var checks = 0;
      final host = appHost(
        env: const AppEnvironment(
          dataSourceMode: DataSourceMode.apiRemote,
          apiBaseUrl: _base,
        ),
        platform: _FakePlatform(),
        client: MockClient((request) async {
          if (request.url.path.endsWith('/latest')) checks += 1;
          return http.Response('{}', 404);
        }),
      );
      await tester.pumpWidget(host);
      await tester.pump(const Duration(milliseconds: 50));
      expect(checks, 1);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(WealthLedgerApp)),
      );
      container.read(themeModeProvider.notifier).toggle();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      container.read(themeModeProvider.notifier).toggle();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(checks, 1, reason: 'rebuild/切主题不得重复请求');
    });

    testWidgets('非 Android：零次请求', (tester) async {
      var checks = 0;
      await tester.pumpWidget(
        appHost(
          env: const AppEnvironment(
            dataSourceMode: DataSourceMode.apiRemote,
            apiBaseUrl: _base,
          ),
          platform: null,
          client: MockClient((request) async {
            if (request.url.path.endsWith('/latest')) checks += 1;
            return http.Response('{}', 404);
          }),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(checks, 0);
    });

    testWidgets('未配置远端零次；配置完成后一次', (tester) async {
      var checks = 0;
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/latest')) checks += 1;
        return http.Response('{}', 404);
      });
      ClientUpdateService? serviceFor(Ref ref) {
        final env = ref.watch(effectiveAppEnvironmentProvider);
        if (!env.hasConfiguredRemoteApi) return null;
        return ClientUpdateService(
          apiBaseUrl: env.apiBaseUrl,
          platform: 'android',
          cacheDirProvider: () async => '',
          client: client,
        );
      }

      final container = ProviderContainer(
        overrides: [
          appEnvironmentProvider.overrideWithValue(
            const AppEnvironment(
              dataSourceMode: DataSourceMode.apiRemote,
              apiBaseUrl: '',
            ),
          ),
          clientUpdatePlatformProvider.overrideWithValue(_FakePlatform()),
          clientUpdateServiceProvider.overrideWith(serviceFor),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const WealthLedgerApp(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(checks, 0, reason: '未配置远端不得请求');

      // 配置完成：环境切到已配置的 HTTPS 远端。
      container.updateOverrides([
        appEnvironmentProvider.overrideWithValue(
          const AppEnvironment(
            dataSourceMode: DataSourceMode.apiRemote,
            apiBaseUrl: _base,
          ),
        ),
        clientUpdatePlatformProvider.overrideWithValue(_FakePlatform()),
        clientUpdateServiceProvider.overrideWith(serviceFor),
      ]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(checks, 1, reason: '配置完成后恰好一次');
    });
  });

  group('P1 授权返回', () {
    test('resume 后权限已开：直接进入可安装态', () async {
      final platform = _FakePlatform(canInstall: false);
      final container = ProviderContainer(
        overrides: [
          clientUpdatePlatformProvider.overrideWithValue(platform),
          clientUpdateServiceProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(appUpdateControllerProvider.notifier);

      // 手动进入 needsPermission（正常路径由 install() 触发）。
      notifier.state = notifier.state.copyWith(
        phase: AppUpdatePhase.needsPermission,
        downloadedPath: 'app.apk',
      );
      await notifier.refreshInstallPermission();
      expect(
        container.read(appUpdateControllerProvider).phase,
        AppUpdatePhase.needsPermission,
        reason: '权限仍未开时保持原状',
      );

      platform.canInstall = true;
      await notifier.refreshInstallPermission();
      expect(
        container.read(appUpdateControllerProvider).phase,
        AppUpdatePhase.readyToInstall,
        reason: '授权后应直接可安装',
      );
    });
  });
}
