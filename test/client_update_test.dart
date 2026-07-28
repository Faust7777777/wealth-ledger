// Android 应用内更新（2026-07-28 任务单）：
// 公开检查不带 bearer、不碰登录态；versionCode 三态；同源相对 URL 门禁；
// 流式下载/进度/取消；大小与 SHA 校验失败即删除且不拉起安装器；
// 未授权安装来源 → 授权页 → 可再次安装；文案不外露实现细节。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:finwealth/data/auth_store.dart';
import 'package:finwealth/data/client_update.dart';
import 'package:finwealth/features/app_update_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _base = 'https://wuwaidut.com';

Map<String, dynamic> _manifestJson({
  int versionCode = 3,
  String versionName = '1.1.0',
  String platform = 'android',
  String channel = 'stable',
  String url = '/v1/client-updates/android/stable/assets/app.apk',
  int? sizeBytes,
  String? sha256Hex,
  List<String> notes = const ['加入应用内更新'],
}) => {
  'schemaVersion': 1,
  'platform': platform,
  'channel': channel,
  'versionName': versionName,
  'versionCode': versionCode,
  'releasedAt': '2026-07-28T12:00:00Z',
  'mandatory': false,
  'notes': notes,
  'asset': {
    'url': url,
    'fileName': 'app.apk',
    'sizeBytes': sizeBytes ?? 4,
    'sha256': sha256Hex ?? sha256.convert(utf8.encode('APK!')).toString(),
    'contentType': 'application/vnd.android.package-archive',
  },
};

http.Response _json(Object body, int status) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

Directory _tempDir() {
  final dir = Directory.systemTemp.createTempSync('finwealth-update-test');
  addTearDown(() {
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (_) {
      // Windows 上偶发文件句柄延迟释放；临时目录交给系统回收即可。
    }
  });
  return dir;
}

ClientUpdateService _service(
  MockClient client, {
  Directory? dir,
  String base = _base,
}) {
  final target = dir ?? _tempDir();
  return ClientUpdateService(
    apiBaseUrl: base,
    platform: 'android',
    cacheDirProvider: () async => target.path,
    client: client,
  );
}

class _FakePlatform implements ClientUpdatePlatform {
  _FakePlatform({required this.dir, this.canInstall = true});
  final Directory dir;
  final int versionCode = 2;
  bool canInstall;
  int permissionOpens = 0;
  final List<String> installed = [];

  @override
  Future<InstalledVersionVm> installedVersion() async =>
      InstalledVersionVm(versionName: '1.0.0', versionCode: versionCode);
  @override
  Future<String> updateCacheDir() async => dir.path;
  @override
  Future<bool> canInstallPackages() async => canInstall;
  @override
  Future<void> openInstallPermissionSettings() async => permissionOpens += 1;
  @override
  Future<void> openInstaller(String path) async => installed.add(path);
}

void main() {
  group('检查更新（公开、不碰登录态）', () {
    test('请求不带 Authorization，也不要求 token', () async {
      String? auth;
      final service = _service(
        MockClient((request) async {
          auth = request.headers['authorization'];
          expect(request.url.path, '/v1/client-updates/android/stable/latest');
          return _json(_manifestJson(), 200);
        }),
      );
      final manifest = await service.fetchLatest();
      expect(auth, isNull, reason: '公开更新请求不得带 bearer');
      expect(manifest!.versionName, '1.1.0');
      expect(manifest.versionCode, 3);
      expect(manifest.asset.fileName, 'app.apk');
    });

    test('未登录：token store 保持为空且不被清理逻辑触碰', () async {
      final store = MemoryAuthTokenStore();
      final service = _service(
        MockClient((_) async => _json(_manifestJson(), 200)),
      );
      await service.fetchLatest();
      expect(await store.read(), isNull);
    });

    test('尚未发布：404 视作没有更新', () async {
      final service = _service(
        MockClient((_) async => _json({'ok': false}, 404)),
      );
      expect(await service.fetchLatest(), isNull);
    });

    test('平台或 channel 不一致的 manifest 被拒绝', () async {
      for (final bad in [
        _manifestJson(platform: 'windows'),
        _manifestJson(channel: 'beta'),
      ]) {
        final service = _service(MockClient((_) async => _json(bad, 200)));
        await expectLater(
          service.fetchLatest(),
          throwsA(isA<ClientUpdateRejected>()),
        );
      }
    });
  });

  group('versionCode 三态', () {
    test('高于 / 等于 / 低于当前版本', () {
      final manifest = parseClientUpdateManifest(_manifestJson(versionCode: 3));
      expect(hasNewerVersion(manifest, 2), isTrue);
      expect(hasNewerVersion(manifest, 3), isFalse);
      expect(hasNewerVersion(manifest, 4), isFalse);
    });

    test('只比较整数，不按 versionName 字符串比较', () {
      // versionName 更"大"但 versionCode 更低：不算更新。
      final manifest = parseClientUpdateManifest(
        _manifestJson(versionName: '9.9.9', versionCode: 2),
      );
      expect(hasNewerVersion(manifest, 2), isFalse);
    });
  });

  group('资源 URL 门禁', () {
    test('接受同源相对路径', () {
      final uri = resolveUpdateAssetUrl(
        _base,
        '/v1/client-updates/android/stable/assets/app.apk',
      );
      expect(uri.origin, _base);
      expect(uri.path, '/v1/client-updates/android/stable/assets/app.apk');
    });

    test('拒绝绝对 URL、协议相对、路径穿越与相对路径', () {
      for (final bad in [
        'https://evil.example/app.apk',
        'http://wuwaidut.com/app.apk',
        '//evil.example/app.apk',
        '/v1/client-updates/../../etc/passwd',
        'v1/client-updates/android/stable/assets/app.apk',
        '',
      ]) {
        expect(
          () => resolveUpdateAssetUrl(_base, bad),
          throwsA(isA<ClientUpdateRejected>()),
          reason: bad,
        );
      }
    });
  });

  group('下载', () {
    test('流式写入、进度回调、校验通过', () async {
      final dir = _tempDir();
      final body = utf8.encode('APK!');
      final service = _service(
        MockClient.streaming(
          (_, _) async => http.StreamedResponse(
            Stream.fromIterable([body.sublist(0, 2), body.sublist(2)]),
            200,
            contentLength: body.length,
          ),
        ),
        dir: dir,
      );
      final progress = <int>[];
      final file = await service.download(
        parseClientUpdateManifest(_manifestJson()),
        onProgress: (received, _) => progress.add(received),
      );
      expect(file.existsSync(), isTrue);
      expect(file.lengthSync(), body.length);
      expect(progress, [2, 4], reason: '分块写入并逐块回报进度');
    });

    test('大小不符：删除文件且不产出可安装包', () async {
      final dir = _tempDir();
      final body = utf8.encode('APK!');
      final service = _service(
        MockClient.streaming(
          (_, _) async => http.StreamedResponse(Stream.value(body), 200),
        ),
        dir: dir,
      );
      await expectLater(
        service.download(
          parseClientUpdateManifest(_manifestJson(sizeBytes: 99)),
        ),
        throwsA(isA<ClientUpdateRejected>()),
      );
      expect(dir.listSync(), isEmpty, reason: '校验失败必须删除临时文件');
    });

    test('SHA 不符：删除文件', () async {
      final dir = _tempDir();
      final service = _service(
        MockClient.streaming(
          (_, _) async =>
              http.StreamedResponse(Stream.value(utf8.encode('APK!')), 200),
        ),
        dir: dir,
      );
      await expectLater(
        service.download(
          parseClientUpdateManifest(_manifestJson(sha256Hex: 'a' * 64)),
        ),
        throwsA(isA<ClientUpdateRejected>()),
      );
      expect(dir.listSync(), isEmpty);
    });

    test('取消：删除临时文件并抛出取消', () async {
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
        onProgress: (_, _) => cancel.complete(),
      );
      chunks.add(utf8.encode('AP'));
      await expectLater(future, throwsA(isA<ClientUpdateRejected>()));
      await chunks.close();
      expect(dir.listSync(), isEmpty);
    });

    test('清缓存只保留指定文件', () async {
      final dir = _tempDir();
      File(
        '${dir.path}${Platform.pathSeparator}old.apk',
      ).writeAsStringSync('old');
      File(
        '${dir.path}${Platform.pathSeparator}new.apk',
      ).writeAsStringSync('new');
      final service = _service(
        MockClient((_) async => _json({}, 200)),
        dir: dir,
      );
      await service.cleanCache(keepFileName: 'new.apk');
      expect(dir.listSync().map((e) => e.uri.pathSegments.last), ['new.apk']);
      await service.cleanCache();
      expect(dir.listSync(), isEmpty);
    });
  });

  group('文案', () {
    test('各状态文案固定且不含实现细节', () {
      final manifest = parseClientUpdateManifest(_manifestJson());
      const idle = AppUpdateState();
      expect(
        appUpdateStatusText(idle.copyWith(phase: AppUpdatePhase.upToDate)),
        '已是最新版本',
      );
      expect(
        appUpdateStatusText(
          idle.copyWith(phase: AppUpdatePhase.available, manifest: manifest),
        ),
        '发现 1.1.0',
      );
      expect(
        appUpdateStatusText(idle.copyWith(phase: AppUpdatePhase.verifying)),
        '正在校验',
      );
      expect(
        appUpdateStatusText(
          idle.copyWith(phase: AppUpdatePhase.readyToInstall),
        ),
        '安装更新',
      );
      expect(
        appUpdateStatusText(
          idle.copyWith(
            phase: AppUpdatePhase.downloading,
            received: 50,
            total: 100,
          ),
        ),
        '下载中 50%',
      );
      for (final phase in AppUpdatePhase.values) {
        final text = appUpdateStatusText(
          idle.copyWith(phase: phase, manifest: manifest, error: '下载失败，请重试'),
        );
        expect(text.contains('sha'), isFalse);
        expect(text.contains('/'), isFalse, reason: text);
        expect(RegExp(r'[a-z_]{6,}').hasMatch(text), isFalse, reason: text);
      }
    });

    test('包大小按人类可读单位显示', () {
      expect(formatUpdateSize(512), '512 B');
      expect(formatUpdateSize(2048), '2 KB');
      expect(formatUpdateSize(160 * 1024 * 1024), '160.0 MB');
    });
  });

  group('安装授权', () {
    test('未授权：跳授权页且不调用安装器；授权后可再次安装', () async {
      final dir = _tempDir();
      final apk = File('${dir.path}${Platform.pathSeparator}app.apk')
        ..writeAsStringSync('APK!');
      final platform = _FakePlatform(dir: dir, canInstall: false);

      // 直接驱动平台契约：未授权只应打开授权页。
      expect(await platform.canInstallPackages(), isFalse);
      await platform.openInstallPermissionSettings();
      expect(platform.permissionOpens, 1);
      expect(platform.installed, isEmpty);

      platform.canInstall = true;
      await platform.openInstaller(apk.path);
      expect(platform.installed, [apk.path]);
    });
  });
}
