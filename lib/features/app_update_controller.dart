// Wealth Ledger — 应用更新状态机。
// 检查/下载/校验全程与账本隔离：失败只反映在这一行 UI 上。
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/env.dart';
import '../data/client_update.dart';
import '../data/providers.dart';

/// 平台侧能力（Android 用 MethodChannel；其他平台不提供更新）。
abstract interface class ClientUpdatePlatform {
  Future<InstalledVersionVm> installedVersion();
  Future<String> updateCacheDir();
  Future<bool> canInstallPackages();
  Future<void> openInstallPermissionSettings();
  Future<void> openInstaller(String path);
}

class AndroidClientUpdatePlatform implements ClientUpdatePlatform {
  const AndroidClientUpdatePlatform();
  static const _channel = MethodChannel('finwealth.client_update');

  @override
  Future<InstalledVersionVm> installedVersion() async {
    final data = await _channel.invokeMapMethod<String, dynamic>(
      'installedVersion',
    );
    return InstalledVersionVm(
      versionName: '${data?['versionName'] ?? ''}',
      versionCode: (data?['versionCode'] as int?) ?? 0,
    );
  }

  @override
  Future<String> updateCacheDir() async =>
      await _channel.invokeMethod<String>('updateCacheDir') ?? '';

  @override
  Future<bool> canInstallPackages() async =>
      await _channel.invokeMethod<bool>('canInstallPackages') ?? false;

  @override
  Future<void> openInstallPermissionSettings() =>
      _channel.invokeMethod<void>('openInstallPermissionSettings');

  @override
  Future<void> openInstaller(String path) =>
      _channel.invokeMethod<void>('openInstaller', {'path': path});
}

enum AppUpdatePhase {
  idle,
  checking,
  upToDate,
  available,
  downloading,
  verifying,
  readyToInstall,
  needsPermission,
  failed,
}

class AppUpdateState {
  const AppUpdateState({
    this.phase = AppUpdatePhase.idle,
    this.installed,
    this.manifest,
    this.received = 0,
    this.total,
    this.error,
    this.downloadedPath,
  });

  final AppUpdatePhase phase;
  final InstalledVersionVm? installed;
  final ClientUpdateManifestVm? manifest;
  final int received;
  final int? total;
  final String? error;
  final String? downloadedPath;

  double? get progress =>
      total == null || total == 0 ? null : received / total!;

  AppUpdateState copyWith({
    AppUpdatePhase? phase,
    InstalledVersionVm? installed,
    Object? manifest = _keep,
    int? received,
    Object? total = _keep,
    Object? error = _keep,
    Object? downloadedPath = _keep,
  }) => AppUpdateState(
    phase: phase ?? this.phase,
    installed: installed ?? this.installed,
    manifest: manifest == _keep
        ? this.manifest
        : manifest as ClientUpdateManifestVm?,
    received: received ?? this.received,
    total: total == _keep ? this.total : total as int?,
    error: error == _keep ? this.error : error as String?,
    downloadedPath: downloadedPath == _keep
        ? this.downloadedPath
        : downloadedPath as String?,
  );

  static const Object _keep = Object();
}

/// 状态 → 用户可见文案。不出现 SHA、路径、endpoint 或实现细节。
String appUpdateStatusText(AppUpdateState state) => switch (state.phase) {
  AppUpdatePhase.checking => '正在检查',
  AppUpdatePhase.upToDate => '已是最新版本',
  AppUpdatePhase.available => '发现 ${state.manifest?.versionName ?? ''}',
  AppUpdatePhase.downloading =>
    state.progress == null
        ? '下载中'
        : '下载中 ${(state.progress! * 100).clamp(0, 100).round()}%',
  AppUpdatePhase.verifying => '正在校验',
  AppUpdatePhase.readyToInstall => '安装更新',
  AppUpdatePhase.needsPermission => '需要允许安装应用',
  AppUpdatePhase.failed => state.error ?? '更新失败',
  AppUpdatePhase.idle => '',
};

String formatUpdateSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

class AppUpdateController extends Notifier<AppUpdateState> {
  Completer<void>? _cancel;
  DateTime? _lastCheck;
  bool _checking = false;

  static const Duration silentInterval = Duration(hours: 24);

  @override
  AppUpdateState build() => const AppUpdateState();

  ClientUpdatePlatform? get _platform => ref.read(clientUpdatePlatformProvider);
  ClientUpdateService? get _service => ref.read(clientUpdateServiceProvider);

  /// 只读取已安装版本（纯本地调用，不发任何网络请求）。
  Future<void> loadInstalledVersion() async {
    final platform = _platform;
    if (platform == null || state.installed != null) return;
    try {
      state = state.copyWith(installed: await platform.installedVersion());
    } catch (_) {
      // 读不到版本不影响其他功能。
    }
  }

  /// 启动后静默检查一次，之后最多 24 小时一次；静默失败不打扰用户。
  Future<void> checkSilently() async {
    final last = _lastCheck;
    if (last != null && DateTime.now().difference(last) < silentInterval) {
      return;
    }
    await _check(silent: true);
  }

  /// 手动检查：失败会显示可重试错误。
  Future<void> check() => _check(silent: false);

  Future<void> _check({required bool silent}) async {
    final platform = _platform;
    final service = _service;
    if (platform == null || service == null) return;
    if (_checking) return; // 同一次点击只发一个请求
    _checking = true;
    if (!silent) state = state.copyWith(phase: AppUpdatePhase.checking);
    try {
      final installed = await platform.installedVersion();
      final manifest = await service.fetchLatest();
      _lastCheck = DateTime.now();
      if (manifest == null ||
          !hasNewerVersion(manifest, installed.versionCode)) {
        // 升级成功后清掉低版本缓存。
        await service.cleanCache();
        state = state.copyWith(
          phase: AppUpdatePhase.upToDate,
          installed: installed,
          manifest: null,
          error: null,
          downloadedPath: null,
        );
        return;
      }
      state = state.copyWith(
        phase: AppUpdatePhase.available,
        installed: installed,
        manifest: manifest,
        error: null,
        downloadedPath: null,
      );
    } on ClientUpdateRejected catch (e) {
      if (!silent) {
        state = state.copyWith(phase: AppUpdatePhase.failed, error: e.reason);
      }
    } catch (_) {
      if (!silent) {
        state = state.copyWith(
          phase: AppUpdatePhase.failed,
          error: '检查更新失败，请稍后重试',
        );
      }
    } finally {
      _checking = false;
    }
  }

  Future<void> download() async {
    final service = _service;
    final manifest = state.manifest;
    if (service == null || manifest == null) return;
    if (state.phase == AppUpdatePhase.downloading) return;
    _cancel = Completer<void>();
    state = state.copyWith(
      phase: AppUpdatePhase.downloading,
      received: 0,
      total: manifest.asset.sizeBytes,
      error: null,
    );
    try {
      final file = await service.download(
        manifest,
        cancel: _cancel!.future,
        onProgress: (received, total) {
          if (state.phase != AppUpdatePhase.downloading) return;
          state = state.copyWith(
            received: received,
            total: total ?? manifest.asset.sizeBytes,
          );
        },
      );
      state = state.copyWith(phase: AppUpdatePhase.verifying);
      await service.cleanCache(keepFileName: file.uri.pathSegments.last);
      state = state.copyWith(
        phase: AppUpdatePhase.readyToInstall,
        downloadedPath: file.path,
      );
    } on ClientUpdateRejected catch (e) {
      state = state.copyWith(
        phase: e.reason == '已取消下载'
            ? AppUpdatePhase.available
            : AppUpdatePhase.failed,
        error: e.reason == '已取消下载' ? null : e.reason,
        downloadedPath: null,
      );
    } catch (_) {
      state = state.copyWith(
        phase: AppUpdatePhase.failed,
        error: '下载失败，请重试',
        downloadedPath: null,
      );
    } finally {
      _cancel = null;
    }
  }

  void cancelDownload() {
    final cancel = _cancel;
    if (cancel != null && !cancel.isCompleted) cancel.complete();
  }

  /// 从系统授权页返回时重新判定权限：已授权就直接回到可安装态，
  /// 用户看到的是「继续安装」而不是还停在「去授权」。
  Future<void> refreshInstallPermission() async {
    if (state.phase != AppUpdatePhase.needsPermission) return;
    final platform = _platform;
    if (platform == null) return;
    try {
      if (await platform.canInstallPackages()) {
        state = state.copyWith(phase: AppUpdatePhase.readyToInstall);
      }
    } catch (_) {
      // 权限查询失败保持原状，用户仍可再点一次。
    }
  }

  /// 拉起系统安装器。没有"安装未知应用"权限时先跳授权页。
  /// 安装是否完成只能由重启后的真实 versionCode 判断，这里不做任何断言。
  Future<void> install() async {
    final platform = _platform;
    final path = state.downloadedPath;
    if (platform == null || path == null) return;
    try {
      if (!await platform.canInstallPackages()) {
        state = state.copyWith(phase: AppUpdatePhase.needsPermission);
        await platform.openInstallPermissionSettings();
        return;
      }
      await platform.openInstaller(path);
      state = state.copyWith(phase: AppUpdatePhase.readyToInstall);
    } catch (_) {
      state = state.copyWith(
        phase: AppUpdatePhase.failed,
        error: '无法打开安装器，请重试',
      );
    }
  }

  /// 删除已下载但未安装的更新包。
  Future<void> discardDownload() async {
    final service = _service;
    final path = state.downloadedPath;
    if (path != null) {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    }
    await service?.cleanCache();
    state = state.copyWith(
      phase: state.manifest == null
          ? AppUpdatePhase.upToDate
          : AppUpdatePhase.available,
      downloadedPath: null,
    );
  }
}

final appUpdateControllerProvider =
    NotifierProvider<AppUpdateController, AppUpdateState>(
      AppUpdateController.new,
    );

/// 只有 Android 提供更新能力；其他平台返回 null，设置页不显示这一行。
final clientUpdatePlatformProvider = Provider<ClientUpdatePlatform?>((ref) {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
  return const AndroidClientUpdatePlatform();
});

/// 更新服务只在 Android + 远端 HTTPS 模式下存在：
/// local_server/DEMO 不向 loopback HTTP 检查更新，也不绕过生产门禁。
final clientUpdateServiceProvider = Provider<ClientUpdateService?>((ref) {
  final platform = ref.watch(clientUpdatePlatformProvider);
  if (platform == null) return null;
  final env = ref.watch(effectiveAppEnvironmentProvider);
  if (env.dataSourceMode != DataSourceMode.apiRemote) return null;
  if (!env.hasConfiguredRemoteApi) return null;
  try {
    requireHttpsOrigin(env.apiBaseUrl);
  } on ClientUpdateRejected {
    return null;
  }
  return ClientUpdateService(
    apiBaseUrl: env.apiBaseUrl,
    platform: 'android',
    cacheDirProvider: platform.updateCacheDir,
  );
});
