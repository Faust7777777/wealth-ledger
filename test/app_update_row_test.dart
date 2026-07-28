// 设置里的「应用更新」行：状态呈现、下载/取消/安装动作、
// 长更新说明进可滚动 sheet、Android 两种窄屏无 overflow。
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:finwealth/data/client_update.dart';
import 'package:finwealth/features/app_update_controller.dart';
import 'package:finwealth/features/app_update_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _base = 'https://wuwaidut.com';
final _body = utf8.encode('APK!');

Map<String, dynamic> _manifestJson({
  int versionCode = 3,
  List<String> notes = const ['加入应用内更新'],
  int? sizeBytes,
}) => {
  'schemaVersion': 1,
  'platform': 'android',
  'channel': 'stable',
  'versionName': '1.1.0',
  'versionCode': versionCode,
  'releasedAt': '2026-07-28T12:00:00Z',
  'mandatory': false,
  'notes': notes,
  'asset': {
    'url': '/v1/client-updates/android/stable/assets/app.apk',
    'fileName': 'app.apk',
    'sizeBytes': sizeBytes ?? _body.length,
    'sha256': sha256.convert(_body).toString(),
    'contentType': 'application/vnd.android.package-archive',
  },
};

class _FakePlatform implements ClientUpdatePlatform {
  _FakePlatform({required this.dir, this.canInstall = true});
  final int versionCode = 2;
  final Directory dir;
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

Directory _tempDir() {
  final dir = Directory.systemTemp.createTempSync('finwealth-row-test');
  addTearDown(() {
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (_) {
      // Windows 上偶发文件句柄延迟释放；临时目录交给系统回收即可。
    }
  });
  return dir;
}

/// 服务替身：只在内存里模拟检查/下载结果，不做真实文件 I/O。
class _FakeService implements ClientUpdateService {
  _FakeService({this.manifest, this.downloadFailure, required this.filePath});
  final ClientUpdateManifestVm? manifest;
  final String? downloadFailure;
  final String filePath;
  int cleanCalls = 0;

  @override
  Future<ClientUpdateManifestVm?> fetchLatest() async => manifest;

  @override
  Future<File> download(
    ClientUpdateManifestVm manifest, {
    UpdateProgress? onProgress,
    Future<void>? cancel,
  }) async {
    onProgress?.call(manifest.asset.sizeBytes, manifest.asset.sizeBytes);
    if (downloadFailure != null) throw ClientUpdateRejected(downloadFailure!);
    return File(filePath);
  }

  @override
  Future<void> cleanCache({String? keepFileName}) async => cleanCalls += 1;

  @override
  String get apiBaseUrl => _base;
  @override
  String get platform => 'android';
  @override
  Future<String> Function() get cacheDirProvider =>
      () async => '';
}

Widget _host({
  required ClientUpdatePlatform? platform,
  ClientUpdateManifestVm? manifest,
  String? downloadFailure,
  String filePath = 'app.apk',
}) => ProviderScope(
  overrides: [
    clientUpdatePlatformProvider.overrideWithValue(platform),
    clientUpdateServiceProvider.overrideWithValue(
      platform == null
          ? null
          : _FakeService(
              manifest: manifest,
              downloadFailure: downloadFailure,
              filePath: filePath,
            ),
    ),
  ],
  child: const MaterialApp(
    home: Scaffold(body: SingleChildScrollView(child: AppUpdateRow())),
  ),
);

void main() {
  testWidgets('无更新能力（非 Android / 本地模式）：整行不显示', (tester) async {
    await tester.pumpWidget(_host(platform: null));
    await tester.pumpAndSettle();
    expect(find.text('应用更新'), findsNothing);
  });

  testWidgets('没有新版本：显示已是最新版本与当前版本', (tester) async {
    final dir = _tempDir();
    await tester.pumpWidget(_host(platform: _FakePlatform(dir: dir)));
    await tester.pumpAndSettle();
    expect(find.text('应用更新'), findsOneWidget);
    expect(find.text('当前版本 1.0.0'), findsOneWidget);
    // 静默检查由 App 启动生命周期触发；这里显式手动检查一次。
    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();
    expect(find.text('已是最新版本'), findsOneWidget);
    expect(find.text('下载更新'), findsNothing);
  });

  testWidgets('有新版本：显示版本号、更新项与包大小，可下载', (tester) async {
    final dir = _tempDir();
    final platform = _FakePlatform(dir: dir);
    await tester.pumpWidget(
      _host(
        platform: platform,
        manifest: parseClientUpdateManifest(_manifestJson()),
        filePath: '${dir.path}${Platform.pathSeparator}app.apk',
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();
    expect(find.text('发现 1.1.0'), findsOneWidget);
    expect(find.textContaining('加入应用内更新'), findsOneWidget);
    expect(find.textContaining('4 B'), findsOneWidget);

    await tester.tap(find.text('下载更新'));
    await tester.pumpAndSettle();
    expect(find.text('安装更新'), findsWidgets);
    expect(find.text('删除下载'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '安装更新'));
    await tester.pumpAndSettle();
    expect(platform.installed, hasLength(1));
    expect(platform.installed.single, endsWith('app.apk'));
  });

  testWidgets('未授权安装来源：跳授权页且不调用安装器', (tester) async {
    final dir = _tempDir();
    final platform = _FakePlatform(dir: dir, canInstall: false);
    await tester.pumpWidget(
      _host(
        platform: platform,
        manifest: parseClientUpdateManifest(_manifestJson()),
        filePath: '${dir.path}${Platform.pathSeparator}app.apk',
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下载更新'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '安装更新'));
    await tester.pumpAndSettle();
    expect(platform.permissionOpens, 1);
    expect(platform.installed, isEmpty);
    expect(find.text('需要允许安装应用'), findsOneWidget);

    // 返回后授权到位：可以再次安装。
    platform.canInstall = true;
    await tester.tap(find.widgetWithText(FilledButton, '继续安装'));
    await tester.pumpAndSettle();
    expect(platform.installed, hasLength(1));
  });

  testWidgets('校验失败：显示可重试错误，不产生可安装包', (tester) async {
    final dir = _tempDir();
    final platform = _FakePlatform(dir: dir);
    await tester.pumpWidget(
      _host(
        platform: platform,
        manifest: parseClientUpdateManifest(_manifestJson()),
        downloadFailure: '更新包校验未通过，请重试',
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下载更新'));
    await tester.pumpAndSettle();
    expect(find.text('更新包校验未通过，请重试'), findsOneWidget);
    expect(find.text('安装更新'), findsNothing);
    expect(platform.installed, isEmpty);
  });

  testWidgets('长更新说明放可滚动 sheet，不挤主页面', (tester) async {
    final dir = _tempDir();
    final notes = [for (var i = 0; i < 12; i += 1) '第 $i 条更新说明，写得比较长一些'];
    await tester.pumpWidget(
      _host(
        platform: _FakePlatform(dir: dir),
        manifest: parseClientUpdateManifest(_manifestJson(notes: notes)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();
    // 主页面只显示第一条摘要。
    expect(find.textContaining('第 0 条更新说明'), findsOneWidget);
    expect(find.textContaining('第 11 条更新说明'), findsNothing);

    await tester.tap(find.text('更新内容'));
    await tester.pumpAndSettle();
    expect(find.textContaining('第 0 条更新说明'), findsWidgets);
    await tester.drag(find.byType(ListView).last, const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android 360×640 与 720×1280 无 overflow', (tester) async {
    for (final size in const [Size(360, 640), Size(720, 1280)]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final dir = _tempDir();
      await tester.pumpWidget(
        _host(
          platform: _FakePlatform(dir: dir),
          manifest: parseClientUpdateManifest(
            _manifestJson(notes: const ['加入应用内更新', '修复会话切换', '附件与报价审核']),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // 两次迭代复用同一个 ProviderScope 容器：已检查过就不会再有该按钮。
      if (find.text('检查更新').evaluate().isNotEmpty) {
        await tester.tap(find.text('检查更新'));
        await tester.pumpAndSettle();
      }
      expect(find.text('发现 1.1.0'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: '${size.width}');
    }
  });
}
